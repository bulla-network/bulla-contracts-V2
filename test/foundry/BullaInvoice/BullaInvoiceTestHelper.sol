pragma solidity ^0.8.30;

import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {BullaInvoice, CreateInvoiceParams} from "src/BullaInvoice.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimApprovalType} from "contracts/types/Types.sol";

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

    /*///////////////////// CONVENIENCE METHODS FOR COMMON PATTERNS /////////////////////*/

    /**
     * @notice Set up all permissions needed for a creditor to manage invoices
     * @param creditorPK The private key of the creditor
     * @param count Number of operations allowed for each permission type
     */
    function _permitCreditorInvoiceOperations(uint256 creditorPK, uint64 count) internal {
        _permitCreateInvoice(creditorPK, count);
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
