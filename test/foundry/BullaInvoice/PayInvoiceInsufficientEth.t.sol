// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {BullaInvoice, CreateInvoiceParams, Invoice, IncorrectMsgValue} from "contracts/BullaInvoice.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";

/**
 * @title TestPayInvoiceInsufficientEth
 * @notice Tests demonstrating BullaInvoice's CORRECT ETH payment validation
 * @dev These tests show that BullaInvoice properly validates msg.value == paymentAmount
 *      This is the secure behavior that BullaClaimV2 should also implement
 */
contract TestPayInvoiceInsufficientEth is Test {
    BullaClaimV2 public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);

    function setUp() public {
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(admin, "ADMIN");

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0 ether, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Create BullaInvoice with 10% protocol fee
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, 1000);

        // Setup balances
        vm.deal(debtor, 100 ether);
        vm.deal(creditor, 100 ether);
        vm.deal(admin, 100 ether);

        // Send ETH to the invoice contract so it has enough balance to potentially handle payments
        vm.deal(address(bullaInvoice), 1000 ether);
    }

    function _createNativeEthInvoice(uint256 claimAmount) private returns (uint256 invoiceId) {
        // Setup permissions for creditor to create invoices
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // Create invoice with native ETH (address(0))
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(0)).withClaimAmount(claimAmount).withLateFeeConfig(
            InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0})
        ) // Native ETH
                // No interest for simplicity
            .build();

        uint256 fee = bullaClaim.CORE_PROTOCOL_FEE();

        vm.prank(creditor);
        invoiceId = bullaInvoice.createInvoice{value: fee}(params);
    }

    function testPayInvoiceInsufficientMsgValue() public {
        uint256 claimAmount = 10 ether;
        uint256 invoiceId = _createNativeEthInvoice(claimAmount);

        uint256 paymentAmount = 10 ether;
        uint256 insufficientMsgValue = 5 ether; // Less than payment amount

        // Verify the contract has enough ETH to potentially handle the transfer
        assertGe(address(bullaInvoice).balance, paymentAmount, "Invoice contract should have enough ETH for payment");

        // Attempt to pay with insufficient msg.value - should revert with IncorrectMsgValue
        vm.prank(debtor);
        vm.expectRevert(IncorrectMsgValue.selector);
        bullaInvoice.payInvoice{value: insufficientMsgValue}(invoiceId, paymentAmount);

        // Verify invoice state remains unchanged
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoice.status), uint256(Status.Pending));
        assertEq(invoice.paidAmount, 0);
    }

    function testPayInvoicePartialInsufficientMsgValue() public {
        uint256 claimAmount = 20 ether;
        uint256 invoiceId = _createNativeEthInvoice(claimAmount);

        uint256 paymentAmount = 8 ether;
        uint256 insufficientMsgValue = 3 ether; // Less than payment amount

        // Verify the contract has enough ETH to potentially handle the transfer
        assertGe(address(bullaInvoice).balance, paymentAmount, "Invoice contract should have enough ETH for payment");

        vm.prank(debtor);
        vm.expectRevert(IncorrectMsgValue.selector);
        bullaInvoice.payInvoice{value: insufficientMsgValue}(invoiceId, paymentAmount);

        // Verify invoice state remains unchanged
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoice.status), uint256(Status.Pending));
        assertEq(invoice.paidAmount, 0);
    }

    function testPayInvoiceWithInterestInsufficientMsgValue() public {
        uint256 claimAmount = 10 ether;

        // Create invoice with interest
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(0)).withClaimAmount(claimAmount).withLateFeeConfig(
            InterestConfig({interestRateBps: 1000, numberOfPeriodsPerYear: 12})
        ) // Native ETH
                // 10% annual interest
            .build();

        uint256 fee = bullaClaim.CORE_PROTOCOL_FEE();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: fee}(params);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;
        uint256 paymentAmount = accruedInterest + 5 ether; // Interest + partial principal
        uint256 insufficientMsgValue = paymentAmount - 1 ether; // Less than required

        // Should revert with IncorrectMsgValue when paying interest + principal with insufficient msg.value
        vm.prank(debtor);
        vm.expectRevert(IncorrectMsgValue.selector);
        bullaInvoice.payInvoice{value: insufficientMsgValue}(invoiceId, paymentAmount);
    }

    function testFuzzPayInvoiceInsufficientMsgValue(uint256 claimAmount, uint256 paymentAmount, uint256 msgValue)
        public
    {
        // Bound inputs to reasonable ranges
        claimAmount = bound(claimAmount, 1 ether, 100 ether);
        paymentAmount = bound(paymentAmount, 1 ether, claimAmount);
        msgValue = bound(msgValue, 0, paymentAmount - 1); // Always less than payment amount

        uint256 invoiceId = _createNativeEthInvoice(claimAmount);

        // Ensure contract has enough ETH
        vm.deal(address(bullaInvoice), claimAmount + 100 ether);

        vm.prank(debtor);
        vm.expectRevert(IncorrectMsgValue.selector); // Should always revert when msg.value < paymentAmount
        bullaInvoice.payInvoice{value: msgValue}(invoiceId, paymentAmount);
    }
}
