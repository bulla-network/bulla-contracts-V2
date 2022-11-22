// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestPayClaimWithFee is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    BullaFeeCalculator public feeCalculator;

    address feeReceiver = address(0xFEE);

    address creditor = address(0xA11c3);
    address debtor = address(0xB0b);
    address charlie = address(0xC44511E);

    function setUp() public {
        weth = new WETH();

        vm.label(address(this), "TEST_CONTRACT");
        vm.label(feeReceiver, "FEE_RECEIVER");

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(charlie, "CHARLIE");

        (bullaClaim,) = (new Deployer()).deploy_test(address(this), feeReceiver, LockState.Unlocked, 0);

        weth.transferFrom(address(this), creditor, 1000 ether);
        weth.transferFrom(address(this), debtor, 1000 ether);
        weth.transferFrom(address(this), charlie, 1000 ether);

        vm.deal(creditor, 1000 ether);
        vm.deal(debtor, 1000 ether);
        vm.deal(charlie, 1000 ether);
    }

    // contract events
    event ClaimPayment(
        uint256 indexed claimId,
        address indexed paidBy,
        uint256 paymentAmount,
        uint256 newPaidAmount,
        uint256 feePaymentAmount
    );

    function _enableFee() private {
        feeCalculator = new BullaFeeCalculator(500);
        bullaClaim.setFeeCalculator(address(feeCalculator));
    }

    function _newClaim(address creator, bool isNative, FeePayer feePayer, uint256 claimAmount)
        private
        returns (uint256 claimId)
    {
        vm.prank(creator);
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: claimAmount,
                dueBy: block.timestamp + 1 days,
                token: isNative ? address(0) : address(weth),
                controller: address(0),
                feePayer: feePayer,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testPaymentNoFee() public {
        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 claimId = _newClaim(creditor, false, FeePayer.Creditor, CLAIM_AMOUNT);

        // store the balance of all parties beforehand
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);
        uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        // approve the ERC20 token
        vm.prank(debtor);
        weth.approve(address(bullaClaim), CLAIM_AMOUNT);

        // expect a payment event with 0 fee
        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, CLAIM_AMOUNT, CLAIM_AMOUNT, 0);

        // call pay claim
        uint256 paymentAmount = CLAIM_AMOUNT;
        vm.prank(debtor);
        bullaClaim.payClaim(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        // assert the debtor paid the amount passed to the function call
        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - paymentAmount);
        // assert no fee was trasnferred
        assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore);
        // assert the creditor received the full payment amount
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + paymentAmount);

        // assert the NFT is transferred to the payer
        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        // assert we change the status to paid
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    function testPayClaimWithNoTransferFlag() public {
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: false
            })
        );

        vm.prank(debtor);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);

        assertEq(bullaClaim.balanceOf(creditor), 1);
        assertEq(bullaClaim.ownerOf(claimId), creditor);
    }

    // same as above but payable for native token transfers
    function testPaymentNoFee_native() public {
        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 claimId = _newClaim(creditor, true, FeePayer.Creditor, CLAIM_AMOUNT);

        uint256 creditorBalanceBefore = creditor.balance;
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 feeReceiverBalanceBefore = feeReceiver.balance;

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, CLAIM_AMOUNT, CLAIM_AMOUNT, 0);

        vm.prank(debtor);
        uint256 paymentAmount = CLAIM_AMOUNT;
        bullaClaim.payClaim{value: paymentAmount}(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        assertEq(debtor.balance, debtorBalanceBefore - paymentAmount);
        assertEq(feeReceiver.balance, feeReceiverBalanceBefore); // no fee
        assertEq(creditor.balance, creditorBalanceBefore + paymentAmount);

        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    function testFullPaymentWithCreditorFee() public {
        // a fee calculator is added
        _enableFee();

        FeePayer feePayer = FeePayer.Creditor;
        uint256 CLAIM_AMOUNT = 100 ether;
        // precalculate the fee amount (we are testing that BullaClaim adhears to the fee calculator, not the calculator itself)
        uint256 FEE_AMOUNT = feeCalculator.calculateFee(
            0, address(0), address(0), address(0), CLAIM_AMOUNT, CLAIM_AMOUNT, 0, 0, ClaimBinding.Unbound, feePayer
        );

        uint256 claimId = _newClaim(creditor, false, feePayer, CLAIM_AMOUNT);
        // record balances before
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);
        uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        uint256 paymentAmount = CLAIM_AMOUNT;

        vm.prank(debtor);
        weth.approve(address(bullaClaim), paymentAmount);

        // expect the fee event to be emitted also
        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, paymentAmount, paymentAmount, FEE_AMOUNT);

        // pay the claim
        vm.prank(debtor);
        bullaClaim.payClaim(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        // assert the debtor paid the amount passed to the function call
        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - paymentAmount);
        // assert the fee was trasnferred
        assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore + FEE_AMOUNT);
        // assert the creditor received the full payment amount minus the fee (remember feePayer == Creditor)
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + paymentAmount - FEE_AMOUNT);

        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    // same as above but native
    function testFullPaymentWithCreditorFee_native() public {
        _enableFee();

        FeePayer feePayer = FeePayer.Creditor;
        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 FEE_AMOUNT = feeCalculator.calculateFee(
            0, address(0), address(0), address(0), CLAIM_AMOUNT, CLAIM_AMOUNT, 0, 0, ClaimBinding.Unbound, feePayer
        );

        uint256 claimId = _newClaim(creditor, true, feePayer, CLAIM_AMOUNT);
        uint256 creditorBalanceBefore = creditor.balance;
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 feeReceiverBalanceBefore = feeReceiver.balance;

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, CLAIM_AMOUNT, CLAIM_AMOUNT, FEE_AMOUNT);

        uint256 paymentAmount = CLAIM_AMOUNT;

        vm.prank(debtor);
        bullaClaim.payClaim{value: paymentAmount}(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        assertEq(debtor.balance, debtorBalanceBefore - paymentAmount);
        assertEq(feeReceiver.balance, feeReceiverBalanceBefore + FEE_AMOUNT);
        assertEq(creditor.balance, creditorBalanceBefore + paymentAmount - FEE_AMOUNT);

        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    // test functionality with the debtor paying the fee
    function testFullPaymentWithDebtorFee() public {
        // spec: test a 100 ether claim is paid with a 5% fee
        _enableFee();

        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 paymentAmount = feeCalculator.fullPaymentAmount(
            0, address(0), address(0), address(0), CLAIM_AMOUNT, 0, 0, ClaimBinding.Unbound, FeePayer.Debtor
        );
        uint256 FEE_AMOUNT = paymentAmount - CLAIM_AMOUNT;

        uint256 claimId = _newClaim(creditor, false, FeePayer.Debtor, CLAIM_AMOUNT);

        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);
        uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        vm.prank(debtor);
        weth.approve(address(bullaClaim), paymentAmount);

        // the event emits the paymentAmount as the amount refected on the claim, not the actual amount paid by the debtor
        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, paymentAmount - FEE_AMOUNT, paymentAmount - FEE_AMOUNT, FEE_AMOUNT);

        vm.prank(debtor);
        // note: the debtor is passing the total claim amount _plus_ the fee into the pay claim function in order to yield a completely paid fee.
        // debtor fees are a little unfriendly to the user/implementer. It would be advantageous to call BullaHelpers before passing an amount to payClaim
        bullaClaim.payClaim(claimId, paymentAmount);

        Claim memory claim = bullaClaim.getClaim(claimId);

        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - paymentAmount);
        assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore + FEE_AMOUNT);

        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + paymentAmount - FEE_AMOUNT);

        assertEq(claim.paidAmount, paymentAmount - FEE_AMOUNT);
        assertEq(claim.claimAmount, claim.paidAmount);
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    // same as above but with native token
    function testFullPaymentWithDebtorFee_native() public {
        _enableFee();

        FeePayer feePayer = FeePayer.Debtor;
        uint256 CLAIM_AMOUNT = 100 ether;

        uint256 claimId = _newClaim(creditor, true, feePayer, CLAIM_AMOUNT);
        Claim memory claim = bullaClaim.getClaim(claimId);

        uint256 paymentAmount = feeCalculator.fullPaymentAmount(
            0, address(0), address(0), address(0), CLAIM_AMOUNT, 0, 0, ClaimBinding.Unbound, feePayer
        );
        uint256 FEE_AMOUNT = paymentAmount - CLAIM_AMOUNT;

        uint256 creditorBalanceBefore = creditor.balance;
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 feeReceiverBalanceBefore = feeReceiver.balance;

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId, debtor, CLAIM_AMOUNT, CLAIM_AMOUNT, FEE_AMOUNT);

        vm.prank(debtor);
        bullaClaim.payClaim{value: paymentAmount}(claimId, paymentAmount);

        claim = bullaClaim.getClaim(claimId);

        assertEq(debtor.balance, debtorBalanceBefore - paymentAmount);
        assertEq(feeReceiver.balance, feeReceiverBalanceBefore + FEE_AMOUNT);
        assertEq(creditor.balance, creditorBalanceBefore + CLAIM_AMOUNT);

        // the NFT is transferred to the payer
        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    // hardcoded, but simple implementation of a half payment
    function testHalfPayment(bool debtorPaysFee) public {
        // spec: pay 1/2 of a 100 ether claim with a 5% fee
        _enableFee();

        uint256 claimId = _newClaim(creditor, false, debtorPaysFee ? FeePayer.Debtor : FeePayer.Creditor, 100 ether);
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);
        uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        uint256 PAYMENT_AMOUNT = debtorPaysFee ? 52.5 ether : 50 ether;
        uint256 EXPECTED_FEE = 2.5 ether;
        uint256 EXPECTED_RECEIVED_AMOUNT = debtorPaysFee ? 50 ether : 47.5 ether;

        vm.prank(debtor);
        weth.approve(address(bullaClaim), 1000 ether);

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(
            claimId,
            debtor,
            debtorPaysFee ? PAYMENT_AMOUNT - EXPECTED_FEE : PAYMENT_AMOUNT,
            debtorPaysFee ? PAYMENT_AMOUNT - EXPECTED_FEE : PAYMENT_AMOUNT,
            EXPECTED_FEE
            );

        vm.prank(debtor);
        bullaClaim.payClaim(claimId, PAYMENT_AMOUNT);

        Claim memory claim = bullaClaim.getClaim(claimId);

        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - PAYMENT_AMOUNT);
        assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore + EXPECTED_FEE);
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + EXPECTED_RECEIVED_AMOUNT);

        assertEq(bullaClaim.ownerOf(claimId), address(creditor));
        assertEq(uint256(claim.status), uint256(Status.Repaying));
    }

    // a fuzzed test test for paying a claim per installment with a creditor fee
    function testPayClaimFuzz_creditorFee(uint8 numberOfPayments) public {
        _enableFee();
        vm.assume(numberOfPayments > 0);

        uint256 CLAIM_AMOUNT = 100 ether;
        uint256 claimId = _newClaim(creditor, false, FeePayer.Creditor, CLAIM_AMOUNT);
        Claim memory claim = bullaClaim.getClaim(claimId);

        vm.prank(debtor);
        weth.approve(address(bullaClaim), type(uint256).max);

        for (uint256 payments = 0; payments < numberOfPayments; payments++) {
            uint256 creditorBalanceBefore = weth.balanceOf(creditor);
            uint256 debtorBalanceBefore = weth.balanceOf(debtor);
            uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);
            uint256 paidAmountBefore = claim.paidAmount;

            bool isLastPayment = payments == numberOfPayments - 1;

            uint256 paymentAmount = isLastPayment
                ? feeCalculator.fullPaymentAmount(
                    0,
                    address(0),
                    address(0),
                    address(0),
                    CLAIM_AMOUNT,
                    claim.paidAmount,
                    0,
                    ClaimBinding.Unbound,
                    FeePayer.Creditor
                )
                : CLAIM_AMOUNT / numberOfPayments;

            uint256 fee = feeCalculator.calculateFee(
                0,
                address(0),
                address(0),
                address(0),
                paymentAmount,
                100 ether,
                0,
                0,
                ClaimBinding.Unbound,
                FeePayer.Creditor
            );

            vm.expectEmit(true, true, true, true, address(bullaClaim));
            emit ClaimPayment(claimId, debtor, paymentAmount, paidAmountBefore + paymentAmount, fee);

            vm.prank(debtor);
            bullaClaim.payClaim(claimId, paymentAmount);
            {
                claim = bullaClaim.getClaim(claimId);

                assertEq(weth.balanceOf(debtor), debtorBalanceBefore - (paymentAmount));

                assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore + fee);

                assertEq(weth.balanceOf(creditor), creditorBalanceBefore + (paymentAmount - fee));

                assertEq(claim.paidAmount, paidAmountBefore + paymentAmount);
            }
        }

        // even after multiple installment payments, expect the claim to still be paid
        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    // same as above but with a debtor fee. This is a bit more complex as the claim is always incrementing paidAmount by (paymentAmount - fee)
    function testPayClaimFuzz_debtorFee(uint8 numberOfPayments) public {
        _enableFee();
        vm.assume(numberOfPayments > 0);
        uint256 CLAIM_AMOUNT = 100 ether;

        uint256 claimId = _newClaim(creditor, false, FeePayer.Debtor, CLAIM_AMOUNT);
        Claim memory claim = bullaClaim.getClaim(claimId);

        vm.prank(debtor);
        weth.approve(address(bullaClaim), type(uint256).max);

        uint256 paymentTotal;
        for (uint256 payments = 0; payments < numberOfPayments; payments++) {
            uint256 creditorBalanceBefore = weth.balanceOf(creditor);
            uint256 debtorBalanceBefore = weth.balanceOf(debtor);
            uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);
            uint256 paidAmountBefore = claim.paidAmount;

            bool isLastPayment = payments == numberOfPayments - 1;

            // if this is the last payment, rely on the feeCalculator to tell us our final fee obligation + the paymentAmount
            uint256 paymentAmount = isLastPayment
                ? feeCalculator.fullPaymentAmount(
                    0,
                    address(0),
                    address(0),
                    address(0),
                    claim.claimAmount,
                    claim.paidAmount,
                    0,
                    ClaimBinding.Unbound,
                    FeePayer.Debtor
                )
                : CLAIM_AMOUNT / numberOfPayments;

            uint256 fee = feeCalculator.calculateFee(
                0,
                address(0),
                address(0),
                address(0),
                paymentAmount,
                100 ether,
                0,
                0,
                ClaimBinding.Unbound,
                FeePayer.Debtor
            );
            paymentTotal += paymentAmount - fee;

            vm.expectEmit(true, true, true, true, address(bullaClaim));
            emit ClaimPayment(claimId, debtor, paymentAmount - fee, paymentTotal, fee);

            vm.prank(debtor);
            bullaClaim.payClaim(claimId, paymentAmount);

            claim = bullaClaim.getClaim(claimId);

            assertEq(weth.balanceOf(debtor), debtorBalanceBefore - (paymentAmount));

            assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore + fee);

            assertEq(weth.balanceOf(creditor), creditorBalanceBefore + (paymentAmount - fee));

            assertEq(claim.paidAmount, paidAmountBefore + paymentAmount - fee);
        }
        assertEq(paymentTotal, CLAIM_AMOUNT);
        assertEq(bullaClaim.ownerOf(claimId), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    // even if another party is paying your claim, they should still pay the initial debtor's fee
    //      - this is so users don't create payment proxy contract that holds tokens (or has some permission) to get reduced fee
    function testPayNotYourClaimEnsureDebtorFee() public {
        _enableFee();
        uint256 CLAIM_AMOUNT = 1 ether;
        uint256 claimId = _newClaim(creditor, false, FeePayer.Debtor, CLAIM_AMOUNT);
        Claim memory claim = bullaClaim.getClaim(claimId);

        uint256 amountOwed = feeCalculator.fullPaymentAmount(
            0, address(0), address(0), address(0), claim.claimAmount, claim.paidAmount, 0, claim.binding, claim.feePayer
        );

        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 charlieBalanceBefore = weth.balanceOf(charlie);
        uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        // have charlie pay the claim
        vm.startPrank(charlie);

        weth.approve(address(bullaClaim), amountOwed);
        bullaClaim.payClaim(claimId, amountOwed);

        claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid));

        vm.stopPrank();

        assertEq(weth.balanceOf(address(feeReceiver)), feeReceiverBalanceBefore + amountOwed - claim.claimAmount);
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore + claim.claimAmount);
        assertEq(weth.balanceOf(charlie), charlieBalanceBefore - amountOwed);
    }
}
