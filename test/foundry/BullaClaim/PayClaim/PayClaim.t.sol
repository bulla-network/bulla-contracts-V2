// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaClaimTestHelper, EIP712Helper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {BaseBullaClaim} from "contracts/BaseBullaClaim.sol";

contract TestPayClaimWithFee is BullaClaimTestHelper {
    address creditor = address(0xA11c3);
    address debtor = address(0xB0b);
    address charlie = address(0xC44511E);

    function setUp() public {
        weth = new WETH();

        vm.label(address(this), "TEST_CONTRACT");

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(charlie, "CHARLIE");

        bullaClaim = (new Deployer()).deploy_test(address(this), LockState.Unlocked, 0);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        weth.transferFrom(address(this), creditor, 1000 ether);
        weth.transferFrom(address(this), debtor, 1000 ether);
        weth.transferFrom(address(this), charlie, 1000 ether);

        vm.deal(creditor, 1000 ether);
        vm.deal(debtor, 1000 ether);
        vm.deal(charlie, 1000 ether);
    }

    // contract events
    event ClaimPayment(uint256 indexed claimId, address indexed paidBy, uint256 paymentAmount, uint256 totalPaidAmount);

    function _newClaim(address creator, bool isNative, uint256 claimAmount) private returns (uint256 claimId) {
        vm.startPrank(creator);
        claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(claimAmount)
                .withToken(isNative ? address(0) : address(weth)).build()
        );
        vm.stopPrank();
    }

    function testPaymentNoFee() public {
        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 claimId = _newClaim(creditor, false, CLAIM_AMOUNT);

        // store the balance of all parties beforehand
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);

        // approve the ERC20 token
        vm.prank(debtor);
        weth.approve(address(bullaClaim), CLAIM_AMOUNT);

        // expect a payment event
        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, CLAIM_AMOUNT, CLAIM_AMOUNT);

        // call pay claim
        uint256 paymentAmount = CLAIM_AMOUNT;
        vm.prank(debtor);
        bullaClaim.payClaim(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        // assert the debtor paid the amount passed to the function call
        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - paymentAmount);
        // assert the creditor received the full payment amount
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + paymentAmount);

        // assert the NFT is transferred to the payer
        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        // assert we change the status to paid
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    function testPayClaimWithNoTransferFlag() public {
        vm.startPrank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withPayerReceivesClaimOnPayment(
                false
            ).build()
        );
        vm.stopPrank();

        vm.prank(debtor);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);

        assertEq(bullaClaim.balanceOf(creditor), 1);
        assertEq(bullaClaim.ownerOf(claimId), creditor);
    }

    // same as above but payable for native token transfers
    function testPaymentNoFee_native() public {
        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        uint256 creditorBalanceBefore = creditor.balance;
        uint256 debtorBalanceBefore = debtor.balance;

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, CLAIM_AMOUNT, CLAIM_AMOUNT);

        vm.prank(debtor);
        uint256 paymentAmount = CLAIM_AMOUNT;
        bullaClaim.payClaim{value: paymentAmount}(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        assertEq(debtor.balance, debtorBalanceBefore - paymentAmount);
        assertEq(creditor.balance, creditorBalanceBefore + paymentAmount);

        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    function testCannotPayAClaimThatDoesntExist() public {
        vm.prank(debtor);
        vm.expectRevert(BaseBullaClaim.NotMinted.selector);
        bullaClaim.payClaim{value: 1 ether}(1, 1 ether);
    }

    function testNonControllerCannotPayClaim() public {
        uint256 userPK = 12345686543;
        address userAddress = vm.addr(userPK);
        address controller = charlie;

        _permitCreateClaim(userPK, controller, 1, CreateClaimApprovalType.Approved, true);

        vm.startPrank(controller);
        bullaClaim.createClaimFrom(
            userAddress,
            new CreateClaimParamsBuilder().withCreditor(userAddress).withDebtor(debtor).withPayerReceivesClaimOnPayment(
                false
            ).build()
        );
        vm.stopPrank();

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BaseBullaClaim.NotController.selector, debtor));
        bullaClaim.payClaim{value: 1 ether}(1, 1 ether);
    }

    function testCannotPayZero() public {
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        vm.expectRevert(BullaClaimValidationLib.PayingZero.selector);
        bullaClaim.payClaim{value: 0}(claimId, 0);
    }

    function testCannotPayClaimWhenLocked() public {
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        bullaClaim.setLockState(LockState.Locked);

        vm.prank(debtor);
        vm.expectRevert(BaseBullaClaim.Locked.selector);
        bullaClaim.payClaim{value: CLAIM_AMOUNT}(claimId, CLAIM_AMOUNT);
    }

    function testCannotOverpay() public {
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.OverPaying.selector, 2 ether));
        bullaClaim.payClaim{value: 2 ether}(claimId, 2 ether);
    }

    function testCannotPayARejectedClaim() public {
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "no. Regards, the debtor");

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        bullaClaim.payClaim{value: CLAIM_AMOUNT}(claimId, CLAIM_AMOUNT);
    }

    function testCannotPayARescindedClaim() public {
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "no. Yours truly, the creditor");

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        bullaClaim.payClaim{value: CLAIM_AMOUNT}(claimId, CLAIM_AMOUNT);
    }

    function testCannotPayAPaidClaim() public {
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, true, CLAIM_AMOUNT);

        vm.prank(debtor);
        bullaClaim.payClaim{value: CLAIM_AMOUNT}(claimId, CLAIM_AMOUNT);

        vm.prank(debtor);
        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);
    }

    // hardcoded, but simple implementation of a half payment
    function testHalfPayment() public {
        // spec: pay 1/2 of a 100 ether claim

        uint256 claimId = _newClaim(creditor, false, 100 ether);
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);

        uint256 PAYMENT_AMOUNT = 50 ether;

        vm.prank(debtor);
        weth.approve(address(bullaClaim), 1000 ether);

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, PAYMENT_AMOUNT, PAYMENT_AMOUNT);

        vm.prank(debtor);
        bullaClaim.payClaim(claimId, PAYMENT_AMOUNT);

        Claim memory claim = bullaClaim.getClaim(claimId);

        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - PAYMENT_AMOUNT);
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + PAYMENT_AMOUNT);

        assertEq(bullaClaim.ownerOf(claimId), address(creditor));
        assertEq(uint256(claim.status), uint256(Status.Repaying));
    }

    function testOriginalCreditorAfterPayment() public {
        vm.startPrank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();

        // Approve and pay claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 1 ether);
        bullaClaim.payClaim(claimId, 1 ether);
        vm.stopPrank();

        // Check ownership transferred but originalCreditor preserved
        assertEq(bullaClaim.ownerOf(claimId), debtor);
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.originalCreditor, creditor);
        assertTrue(claim.status == Status.Paid);
    }
}
