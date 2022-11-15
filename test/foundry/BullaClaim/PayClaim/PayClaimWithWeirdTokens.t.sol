// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {RevertingToken} from "solmate/test/utils/weird-tokens/RevertingToken.sol";
import {ReturnsTwoToken} from "solmate/test/utils/weird-tokens/ReturnsTwoToken.sol";
import {ReturnsFalseToken} from "solmate/test/utils/weird-tokens/ReturnsFalseToken.sol";
import {MissingReturnToken} from "solmate/test/utils/weird-tokens/MissingReturnToken.sol";
import {ReturnsTooMuchToken} from "solmate/test/utils/weird-tokens/ReturnsTooMuchToken.sol";
import {ReturnsGarbageToken} from "solmate/test/utils/weird-tokens/ReturnsGarbageToken.sol";
import {ReturnsTooLittleToken} from "solmate/test/utils/weird-tokens/ReturnsTooLittleToken.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {FeeOnTransferToken} from "contracts/mocks/FeeOnTransferToken.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestPayClaimWithWeirdTokens is Test {
    using Strings for uint256;

    MockERC20 erc20;
    RevertingToken reverting;
    ReturnsTwoToken returnsTwo;
    ReturnsFalseToken returnsFalse;
    MissingReturnToken missingReturn;
    ReturnsTooMuchToken returnsTooMuch;
    ReturnsGarbageToken returnsGarbage;
    ReturnsTooLittleToken returnsTooLittle;

    BullaClaim bullaClaim;
    BullaFeeCalculator feeCalculator;

    address feeReceiver = address(0xFEE);
    address creditor = address(0xA11c3);
    address debtor = address(0xB0b);

    function setUp() public {
        vm.label(feeReceiver, "FEE_RECEIVER");
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(address(this), "TEST_CONTRACT");

        (bullaClaim,) = (new Deployer()).deploy_test(address(this), feeReceiver, LockState.Unlocked, 0);

        reverting = new RevertingToken();
        returnsTwo = new ReturnsTwoToken();
        returnsFalse = new ReturnsFalseToken();
        missingReturn = new MissingReturnToken();
        returnsTooMuch = new ReturnsTooMuchToken();
        returnsGarbage = new ReturnsGarbageToken();
        returnsTooLittle = new ReturnsTooLittleToken();

        erc20 = new MockERC20("StandardToken", "ST", 18);
        erc20.mint(address(this), type(uint256).max);
    }

    // contract events
    event ClaimPayment(uint256 indexed claimId, address indexed paidBy, uint256 paymentAmount, uint256 feeAmount);

    function _enableFee() private {
        feeCalculator = new BullaFeeCalculator(500);
        bullaClaim.setFeeCalculator(address(feeCalculator));
    }

    function _newClaim(address token, FeePayer feePayer, uint256 claimAmount) private returns (uint256 claimId) {
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: claimAmount,
                dueBy: block.timestamp + 1 days,
                token: token,
                delegator: address(0),
                feePayer: feePayer,
                binding: ClaimBinding.Unbound
            })
        );
    }

    // from solmate/test/utils/weird-tokens
    function _forceApprove(address token, address from, address to, uint256 amount) internal {
        uint256 slot = token == address(erc20) ? 4 : 2; // Standard ERC20 name and symbol aren't constant.

        vm.store(token, keccak256(abi.encode(to, keccak256(abi.encode(from, uint256(slot))))), bytes32(uint256(amount)));

        assertEq(MockERC20(token).allowance(from, to), amount, "wrong allowance");
    }

    function testSolmateWeirdTokens() public {
        uint256 CLAIM_AMOUNT = 100 ether;

        ERC20[] memory tokens = new ERC20[](7);
        tokens[0] = ERC20(address(new RevertingToken()));
        tokens[1] = ERC20(address(new ReturnsTwoToken()));
        tokens[2] = ERC20(address(new ReturnsFalseToken()));
        tokens[3] = ERC20(address(new MissingReturnToken()));
        tokens[4] = ERC20(address(new ReturnsTooMuchToken()));
        tokens[5] = ERC20(address(new ReturnsGarbageToken()));
        tokens[6] = ERC20(address(new ReturnsTooLittleToken()));

        for (uint256 i = 0; i < tokens.length; i++) {
            ERC20 token = tokens[i];

            vm.prank(creditor);
            uint256 claimId = _newClaim(address(token), FeePayer.Creditor, CLAIM_AMOUNT);

            uint256 creditorBalanceBefore = token.balanceOf(creditor);
            uint256 debtorBalanceBefore = token.balanceOf(debtor);
            uint256 feeReceiverBalanceBefore = token.balanceOf(feeReceiver);

            _forceApprove(address(token), debtor, address(bullaClaim), CLAIM_AMOUNT);

            vm.prank(debtor);
            vm.expectRevert("TRANSFER_FROM_FAILED");
            bullaClaim.payClaim(claimId, CLAIM_AMOUNT);

            Claim memory claim = bullaClaim.getClaim(claimId);

            //ensure no tokens transferred in the case of strange reverts
            assertEq(token.balanceOf(debtor), debtorBalanceBefore, string.concat("Fail on token: ", i.toString()));
            assertEq(
                token.balanceOf(feeReceiver), feeReceiverBalanceBefore, string.concat("Fail on token: ", i.toString())
            );
            assertEq(token.balanceOf(creditor), creditorBalanceBefore, string.concat("Fail on token: ", i.toString()));

            assertEq(bullaClaim.ownerOf(claimId), address(creditor), string.concat("Fail on token: ", i.toString()));
            assertEq(uint256(claim.status), uint256(Status.Pending), string.concat("Fail on token: ", i.toString()));
        }
    }

    function testFeeOnTransferToken_noBullaFee() public {
        uint256 CLAIM_AMOUNT = 100 ether;
        // has a built in 1% fee on transfer
        FeeOnTransferToken feeToken = new FeeOnTransferToken();

        Claim memory claim;
        uint256 creditorBalanceBefore;
        uint256 debtorBalanceBefore;
        uint256 feeReceiverBalanceBefore;
        uint256 tokenFeeAmount;

        feeToken.mint(debtor, CLAIM_AMOUNT * 2);
        tokenFeeAmount = (CLAIM_AMOUNT * feeToken.FEE_BPS()) / 10000;

        vm.prank(creditor);
        uint256 claimId_creditorFee = _newClaim(address(feeToken), FeePayer.Creditor, CLAIM_AMOUNT);

        creditorBalanceBefore = feeToken.balanceOf(creditor);
        debtorBalanceBefore = feeToken.balanceOf(debtor);
        feeReceiverBalanceBefore = feeToken.balanceOf(feeReceiver);

        vm.prank(debtor);
        feeToken.approve(address(bullaClaim), CLAIM_AMOUNT * 2);

        // expect amountPaid in the event to equal the amount transferred from the debtor
        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId_creditorFee, debtor, CLAIM_AMOUNT, 0);

        vm.prank(debtor);
        bullaClaim.payClaim(claimId_creditorFee, CLAIM_AMOUNT);

        claim = bullaClaim.getClaim(claimId_creditorFee);

        // ensure no tokens transferred
        assertEq(feeToken.balanceOf(debtor), debtorBalanceBefore - CLAIM_AMOUNT);
        assertEq(feeToken.balanceOf(feeReceiver), feeReceiverBalanceBefore);
        assertEq(feeToken.balanceOf(creditor), creditorBalanceBefore + CLAIM_AMOUNT - tokenFeeAmount);

        assertEq(bullaClaim.ownerOf(claimId_creditorFee), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));

        // ensure debtor fee
        vm.prank(creditor);
        uint256 claimId_debtorFee = _newClaim(address(feeToken), FeePayer.Debtor, CLAIM_AMOUNT);

        creditorBalanceBefore = feeToken.balanceOf(creditor);
        debtorBalanceBefore = feeToken.balanceOf(debtor);
        feeReceiverBalanceBefore = feeToken.balanceOf(feeReceiver);

        // expect amountPaid in the event to equal the amount transferred from the debtor
        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId_debtorFee, debtor, CLAIM_AMOUNT, 0);

        vm.prank(debtor);
        bullaClaim.payClaim(claimId_debtorFee, CLAIM_AMOUNT);

        claim = bullaClaim.getClaim(claimId_debtorFee);

        assertEq(feeToken.balanceOf(debtor), debtorBalanceBefore - CLAIM_AMOUNT);
        assertEq(feeToken.balanceOf(feeReceiver), feeReceiverBalanceBefore);
        assertEq(feeToken.balanceOf(creditor), creditorBalanceBefore + CLAIM_AMOUNT - tokenFeeAmount);

        assertEq(bullaClaim.ownerOf(claimId_debtorFee), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }

    function testFeeOnTransferToken_withBullaFee() public {
        _enableFee();
        uint256 CLAIM_AMOUNT = 100 ether;
        FeeOnTransferToken feeToken = new FeeOnTransferToken();

        Claim memory claim;
        uint256 creditorBalanceBefore;
        uint256 debtorBalanceBefore;
        uint256 feeReceiverBalanceBefore;
        uint256 tokenFeeAmount;
        uint256 bullaFeeAmount = feeCalculator.calculateFee(
            0,
            address(0),
            address(0),
            address(0),
            CLAIM_AMOUNT,
            CLAIM_AMOUNT,
            0,
            0,
            ClaimBinding.Unbound,
            FeePayer.Creditor
        );

        tokenFeeAmount = (CLAIM_AMOUNT * feeToken.FEE_BPS()) / 10000;

        feeToken.mint(debtor, CLAIM_AMOUNT * 10);
        vm.prank(debtor);
        feeToken.approve(address(bullaClaim), CLAIM_AMOUNT * 10);

        vm.prank(creditor);
        uint256 claimId_creditorFee = _newClaim(address(feeToken), FeePayer.Creditor, CLAIM_AMOUNT);

        creditorBalanceBefore = feeToken.balanceOf(creditor);
        debtorBalanceBefore = feeToken.balanceOf(debtor);
        feeReceiverBalanceBefore = feeToken.balanceOf(feeReceiver);

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId_creditorFee, debtor, CLAIM_AMOUNT, bullaFeeAmount);

        vm.prank(debtor);
        bullaClaim.payClaim(claimId_creditorFee, CLAIM_AMOUNT);

        claim = bullaClaim.getClaim(claimId_creditorFee);

        assertEq(feeToken.balanceOf(debtor), debtorBalanceBefore - CLAIM_AMOUNT);
        assertEq(
            feeToken.balanceOf(feeReceiver),
            feeReceiverBalanceBefore + bullaFeeAmount - (bullaFeeAmount * feeToken.FEE_BPS()) / 10000
        );
        assertEq(
            feeToken.balanceOf(creditor),
            creditorBalanceBefore + (CLAIM_AMOUNT - bullaFeeAmount)
                - (((CLAIM_AMOUNT - bullaFeeAmount) * feeToken.FEE_BPS()) / 10000)
        );

        assertEq(bullaClaim.ownerOf(claimId_creditorFee), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));

        // ensure debtor fee
        vm.prank(creditor);
        uint256 claimId_debtorFee = _newClaim(address(feeToken), FeePayer.Debtor, CLAIM_AMOUNT);

        claim = bullaClaim.getClaim(claimId_debtorFee);
        uint256 fullPaymentAmount = feeCalculator.fullPaymentAmount(
            0,
            address(0),
            address(0),
            address(0),
            claim.claimAmount,
            claim.paidAmount,
            0,
            ClaimBinding.Unbound,
            FeePayer.Debtor
        );
        bullaFeeAmount = feeCalculator.calculateFee(
            0,
            address(0),
            address(0),
            address(0),
            fullPaymentAmount,
            100 ether,
            0,
            0,
            ClaimBinding.Unbound,
            FeePayer.Debtor
        );

        creditorBalanceBefore = feeToken.balanceOf(creditor);
        debtorBalanceBefore = feeToken.balanceOf(debtor);
        feeReceiverBalanceBefore = feeToken.balanceOf(feeReceiver);

        vm.expectEmit(true, true, true, true, address(bullaClaim));
        emit ClaimPayment(claimId_debtorFee, debtor, CLAIM_AMOUNT, bullaFeeAmount);

        vm.prank(debtor);
        bullaClaim.payClaim(claimId_debtorFee, fullPaymentAmount);

        claim = bullaClaim.getClaim(claimId_debtorFee);

        assertEq(feeToken.balanceOf(debtor), debtorBalanceBefore - fullPaymentAmount);
        assertEq(
            feeToken.balanceOf(feeReceiver),
            feeReceiverBalanceBefore + bullaFeeAmount - ((bullaFeeAmount * feeToken.FEE_BPS()) / 10000)
        );
        assertEq(feeToken.balanceOf(creditor), creditorBalanceBefore + CLAIM_AMOUNT - tokenFeeAmount);

        assertEq(bullaClaim.ownerOf(claimId_debtorFee), address(debtor));
        assertEq(uint256(claim.status), uint256(Status.Paid));
    }
}
