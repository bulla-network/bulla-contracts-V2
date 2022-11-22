// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestBullaFeeCalculatorV1 is Test {
    using FixedPointMathLib for *;

    uint256 FEE_BPS = 500;
    WETH public weth;
    BullaClaim public bullaClaim;
    BullaFeeCalculator feeCalculator;

    address alice = address(0xA11cE);
    address contractOwner = address(0xB0b);
    address creditor = address(0x01);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    function setUp() public {
        weth = new WETH();

        (bullaClaim, feeCalculator) =
            (new Deployer()).deploy_test(contractOwner, feeReceiver, LockState.Unlocked, FEE_BPS);
        vm.deal(debtor, type(uint128).max);
    }

    function testAdjustFee() public {
        vm.prank(contractOwner);
        feeCalculator = new BullaFeeCalculator(FEE_BPS);

        uint256 NEW_FEE = 100;
        vm.prank(contractOwner);
        feeCalculator.updateFee(NEW_FEE);

        assertEq(feeCalculator.feeBPS(), NEW_FEE);
    }

    function testNonOwnerCannotAdjustFee() public {
        vm.prank(contractOwner);
        feeCalculator = new BullaFeeCalculator(FEE_BPS);

        uint256 NEW_FEE = 100;

        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        feeCalculator.updateFee(NEW_FEE);
    }

    function testCanTransferOwnership() public {
        vm.prank(contractOwner);
        feeCalculator = new BullaFeeCalculator(FEE_BPS);

        vm.prank(contractOwner);
        feeCalculator.setOwner(alice);

        assertEq(feeCalculator.owner(), alice);
    }

    // spec:
    //      given: any token (even with strange decimals), any claimAmount, any amount to be paid, or any party as the feepayer
    //      result: a call to fullPaymentAmount() will return the amount left to pay + any fee obligation
    function test_FUZZ_fullPaymentAmount(
        uint8 _tokenDecmals,
        uint128 claimAmount,
        bool debtorPaysFee,
        bool includePartialPayment
    ) public {
        // bind decimals to > 1 && < 18
        uint8 tokenDecmals = _tokenDecmals % 19;
        vm.assume(tokenDecmals > 1);
        // ensure claim amount is above BASIS_POINTS / FEE_BPS to even allow for a fee to be collected (fee will naturally be 0 due to lack of token precision)
        vm.assume(claimAmount > 1e2);

        MockERC20 mockToken = new MockERC20("test", "TST", tokenDecmals);
        mockToken.mint(debtor, claimAmount);

        FeePayer feePayer = debtorPaysFee ? FeePayer.Debtor : FeePayer.Creditor;

        vm.prank(contractOwner);
        feeCalculator = new BullaFeeCalculator(FEE_BPS);

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: claimAmount,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: feePayer,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );

        if (includePartialPayment) {
            uint256 amount = claimAmount / 2;

            vm.prank(debtor);
            bullaClaim.payClaim{value: amount}(claimId, amount);
        }

        Claim memory claim = bullaClaim.getClaim(claimId);

        uint256 fullPaymentAmount = feeCalculator.fullPaymentAmount(
            claimId,
            debtor, // debtor pays
            creditor,
            debtor,
            claim.claimAmount,
            claim.paidAmount,
            claim.dueBy,
            claim.binding,
            claim.feePayer
        );

        uint256 amountRemaining = claimAmount - claim.paidAmount;
        uint256 expectedPaymentAmount = amountRemaining
            + (
                feePayer == FeePayer.Debtor
                    ? amountRemaining.mulDivDown(FEE_BPS, 10000) // a debtor's obligated to pay the fee too
                    : 0
            );

        assertEq(fullPaymentAmount, expectedPaymentAmount);
    }

    // spec:
    //      given: any token (even with strange decimals), any claimAmount, any paymentAmount, any amount to be paid, or any party as the feepayer
    //      result: a call to calculateFee() will return a debtor's obligation of payment
    function test_FUZZ_calculateFee(
        uint8 _tokenDecmals,
        uint128 claimAmount,
        uint128 paymentAmount,
        bool debtorPaysFee,
        bool includePartialPayment
    ) public {
        FeePayer feePayer = debtorPaysFee ? FeePayer.Debtor : FeePayer.Creditor;

        // same checks and binds as above
        uint8 tokenDecmals = _tokenDecmals % 19;
        vm.assume(tokenDecmals > 1);
        vm.assume(claimAmount > 1e2 && paymentAmount > 1e2 && paymentAmount <= claimAmount);

        vm.prank(contractOwner);
        feeCalculator = new BullaFeeCalculator(FEE_BPS);

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: claimAmount,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: feePayer,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );

        if (includePartialPayment) {
            uint256 amount = claimAmount / 2;

            vm.prank(debtor);
            bullaClaim.payClaim{value: amount}(claimId, amount);
        }

        Claim memory claim = bullaClaim.getClaim(claimId);

        uint256 amountRemaining = claim.claimAmount - claim.paidAmount;

        uint256 fee = feeCalculator.calculateFee(
            claimId,
            debtor, // debtor is payer
            creditor,
            debtor,
            amountRemaining,
            claim.claimAmount,
            claim.paidAmount,
            claim.dueBy,
            claim.binding,
            claim.feePayer
        );

        assertTrue(fee < amountRemaining);

        uint256 expectedFee;
        if (feePayer == FeePayer.Creditor) {
            expectedFee = amountRemaining.mulDivDown(FEE_BPS, 10000);
        } else {
            uint256 claimFee = claimAmount.mulDivDown(FEE_BPS, 10000);

            expectedFee = claimFee.mulDivDown(amountRemaining, (claimFee + claimAmount));
        }

        assertEq(fee, expectedFee);
    }
}
