// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {BullaInvoice, CreateInvoiceParams} from "src/BullaInvoice.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimApprovalType, PayClaimApprovalType, ClaimPaymentApprovalParam} from "contracts/types/Types.sol";

/**
 * @title BullaInvoiceTestHelper
 * @notice Test helper contract that extends BullaClaimTestHelper with invoice-specific functionality
 * @dev Provides convenience methods for setting up permits and creating invoices in tests
 */
contract BullaInvoiceTestHelper is BullaClaimTestHelper {
    BullaInvoice public bullaInvoice;

    /*///////////////////// INVOICE-SPECIFIC PERMIT HELPERS /////////////////////*/

    /**
     * @notice Set up create invoice permissions for a user
     * @param userPK The private key of the user
     * @param count Number of invoices the user can create
     * @param isBindingAllowed Whether binding operations are allowed
     */
    function _permitCreateInvoice(uint256 userPK, uint64 count, bool isBindingAllowed) internal {
        _permitCreateClaim(userPK, address(bullaInvoice), count, CreateClaimApprovalType.Approved, isBindingAllowed);
    }

    /**
     * @notice Set up create invoice permissions for a user (with binding allowed)
     * @param userPK The private key of the user
     * @param count Number of invoices the user can create
     */
    function _permitCreateInvoice(uint256 userPK, uint64 count) internal {
        _permitCreateInvoice(userPK, count, true);
    }

    /**
     * @notice Set up create invoice permissions for a user (single invoice, binding allowed)
     * @param userPK The private key of the user
     */
    function _permitCreateInvoice(uint256 userPK) internal {
        _permitCreateInvoice(userPK, 1, true);
    }

    /**
     * @notice Set up pay invoice permissions for a user (approve all)
     * @param userPK The private key of the user
     */
    function _permitPayInvoice(uint256 userPK) internal {
        _permitPayClaim(
            userPK, address(bullaInvoice), PayClaimApprovalType.IsApprovedForAll, 0, new ClaimPaymentApprovalParam[](0)
        );
    }

    /**
     * @notice Set up update binding permissions for a user
     * @param userPK The private key of the user
     * @param count Number of binding updates allowed
     */
    function _permitUpdateInvoiceBinding(uint256 userPK, uint64 count) internal {
        _permitUpdateBinding(userPK, address(bullaInvoice), count);
    }

    /**
     * @notice Set up update binding permissions for a user (single update)
     * @param userPK The private key of the user
     */
    function _permitUpdateInvoiceBinding(uint256 userPK) internal {
        _permitUpdateInvoiceBinding(userPK, 1);
    }

    /**
     * @notice Set up cancel invoice permissions for a user
     * @param userPK The private key of the user
     * @param count Number of cancellations allowed
     */
    function _permitCancelInvoice(uint256 userPK, uint64 count) internal {
        _permitCancelClaim(userPK, address(bullaInvoice), count);
    }

    /**
     * @notice Set up cancel invoice permissions for a user (single cancellation)
     * @param userPK The private key of the user
     */
    function _permitCancelInvoice(uint256 userPK) internal {
        _permitCancelInvoice(userPK, 1);
    }

    /**
     * @notice Set up impair invoice permissions for a user
     * @param userPK The private key of the user
     * @param count Number of impairments allowed
     */
    function _permitImpairInvoice(uint256 userPK, uint64 count) internal {
        _permitImpairClaim(userPK, address(bullaInvoice), count);
    }

    /**
     * @notice Set up impair invoice permissions for a user (single impairment)
     * @param userPK The private key of the user
     */
    function _permitImpairInvoice(uint256 userPK) internal {
        _permitImpairInvoice(userPK, 1);
    }

    /**
     * @notice Set up mark as paid permissions for a user
     * @param userPK The private key of the user
     * @param count Number of mark-as-paid operations allowed
     */
    function _permitMarkInvoiceAsPaid(uint256 userPK, uint64 count) internal {
        _permitMarkAsPaid(userPK, address(bullaInvoice), count);
    }

    /**
     * @notice Set up mark as paid permissions for a user (single operation)
     * @param userPK The private key of the user
     */
    function _permitMarkInvoiceAsPaid(uint256 userPK) internal {
        _permitMarkInvoiceAsPaid(userPK, 1);
    }

    /*///////////////////// CONVENIENCE METHODS FOR COMMON PATTERNS /////////////////////*/

    /**
     * @notice Set up all permissions needed for a creditor to manage invoices
     * @param creditorPK The private key of the creditor
     * @param count Number of operations allowed for each permission type
     */
    function _permitCreditorInvoiceOperations(uint256 creditorPK, uint64 count) internal {
        _permitCreateInvoice(creditorPK, count);
        _permitCancelInvoice(creditorPK, count);
        _permitImpairInvoice(creditorPK, count);
        _permitMarkInvoiceAsPaid(creditorPK, count);
    }

    /**
     * @notice Set up all permissions needed for a debtor to interact with invoices
     * @param debtorPK The private key of the debtor
     * @param count Number of operations allowed for each permission type
     */
    function _permitDebtorInvoiceOperations(uint256 debtorPK, uint64 count) internal {
        _permitPayInvoice(debtorPK);
        _permitUpdateInvoiceBinding(debtorPK, count);
    }

    /*///////////////////// INVOICE CREATION HELPERS /////////////////////*/

    /**
     * @notice Create a simple invoice with minimal setup
     * @param creditorPK The private key of the creditor
     * @param debtor The debtor address
     * @return invoiceId The ID of the created invoice
     */
    function _createSimpleInvoice(uint256 creditorPK, address debtor) internal returns (uint256 invoiceId) {
        address creditor = vm.addr(creditorPK);
        _permitCreateInvoice(creditorPK);

        vm.prank(creditor);
        invoiceId = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor).build()
        );
    }

    /**
     * @notice Create an invoice with custom parameters
     * @param creditorPK The private key of the creditor
     * @param params The invoice creation parameters
     * @return invoiceId The ID of the created invoice
     */
    function _createInvoiceWithParams(uint256 creditorPK, CreateInvoiceParams memory params)
        internal
        returns (uint256 invoiceId)
    {
        address creditor = vm.addr(creditorPK);
        _permitCreateInvoice(creditorPK);

        vm.prank(creditor);
        invoiceId = bullaInvoice.createInvoice(params);
    }

    /**
     * @notice Create multiple invoices for batch testing
     * @param creditorPK The private key of the creditor
     * @param debtors Array of debtor addresses
     * @return invoiceIds Array of created invoice IDs
     */
    function _createMultipleInvoices(uint256 creditorPK, address[] memory debtors)
        internal
        returns (uint256[] memory invoiceIds)
    {
        address creditor = vm.addr(creditorPK);
        _permitCreateInvoice(creditorPK, uint64(debtors.length));

        invoiceIds = new uint256[](debtors.length);
        vm.startPrank(creditor);
        for (uint256 i = 0; i < debtors.length; i++) {
            invoiceIds[i] = bullaInvoice.createInvoice(
                new CreateInvoiceParamsBuilder().withDebtor(debtors[i]).withCreditor(creditor).build()
            );
        }
        vm.stopPrank();
    }
}
