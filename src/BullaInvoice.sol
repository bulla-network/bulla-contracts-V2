// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/BullaClaimControllerBase.sol";
import "contracts/types/Types.sol";

// Data specific to invoices and not claims
struct InvoiceDetails {
    uint256 dueBy;
}

error InvalidDueBy();

struct Invoice {
    uint256 claimAmount;
    uint256 paidAmount;
    Status status;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
    address debtor;
    address token;
    uint256 dueBy;
}

struct CreateInvoiceParams {
    address creditor;
    address debtor;
    uint256 claimAmount;
    uint256 dueBy;
    string description;
    address token;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
}

/**
 * @title BullaInvoice
 * @notice A wrapper contract for IBullaClaim that delegates all calls to the provided contract instance
 */
contract BullaInvoice is BullaClaimControllerBase {
    mapping(uint256 => InvoiceDetails) private _invoiceDetailsByClaimId;

    event InvoiceCreated(uint256 claimId, uint256 dueBy);

    /**
     * @notice Constructor
     * @param bullaClaim Address of the IBullaClaim contract to delegate calls to
     */
    constructor(address bullaClaim) BullaClaimControllerBase(bullaClaim) {}

    /**
     * @notice Get an invoice
     * @param claimId The ID of the invoice to get
     * @return The invoice
     */
    function getInvoice(uint256 claimId) external view returns (Invoice memory) {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        return Invoice({
            claimAmount: claim.claimAmount,
            paidAmount: claim.paidAmount,
            status: claim.status,
            binding: claim.binding,
            payerReceivesClaimOnPayment: claim.payerReceivesClaimOnPayment,
            debtor: claim.debtor,
            token: claim.token,
            dueBy: invoiceDetails.dueBy
        });
    }

    /**
     * @notice Creates an invoice
     * @param params The parameters for creating an invoice
     * @return The ID of the created invoice
     */
    function createInvoice(CreateInvoiceParams memory params) external returns (uint256) {
        _validateCreateInvoiceParams(params);

        CreateClaimParams memory createClaimParams = CreateClaimParams({
            creditor: params.creditor,
            debtor: params.debtor,
            claimAmount: params.claimAmount,
            description: params.description,
            token: params.token,
            binding: params.binding,
            payerReceivesClaimOnPayment: params.payerReceivesClaimOnPayment
        });

        uint256 claimId = _bullaClaim.createClaimFrom(msg.sender, createClaimParams);
        _invoiceDetailsByClaimId[claimId] = InvoiceDetails({dueBy: params.dueBy});

        emit InvoiceCreated(claimId, params.dueBy);

        return claimId;
    }

    /**
     * @notice Creates an invoice with metadata
     * @param params The parameters for creating an invoice
     * @param metadata The metadata for the invoice
     * @return The ID of the created invoice
     */
    function createInvoiceWithMetadata(CreateInvoiceParams memory params, ClaimMetadata memory metadata)
        external
        returns (uint256)
    {
        _validateCreateInvoiceParams(params);

        CreateClaimParams memory createClaimParams = CreateClaimParams({
            creditor: params.creditor,
            debtor: params.debtor,
            claimAmount: params.claimAmount,
            description: params.description,
            token: params.token,
            binding: params.binding,
            payerReceivesClaimOnPayment: params.payerReceivesClaimOnPayment
        });

        uint256 claimId = _bullaClaim.createClaimWithMetadataFrom(msg.sender, createClaimParams, metadata);

        _invoiceDetailsByClaimId[claimId] = InvoiceDetails({dueBy: params.dueBy});

        emit InvoiceCreated(claimId, params.dueBy);

        return claimId;
    }

    /**
     * @notice Pays an invoice
     * @param claimId The ID of the invoice to pay
     * @param amount The amount to pay
     */
    function payInvoice(uint256 claimId, uint256 amount) external payable {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.payClaimFrom{value: msg.value}(msg.sender, claimId, amount);
    }

    /**
     * @notice Updates the binding of an invoice
     * @param claimId The ID of the invoice to update
     * @param binding The new binding for the invoice
     */
    function updateBinding(uint256 claimId, ClaimBinding binding) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.updateBindingFrom(msg.sender, claimId, binding);
    }

    /**
     * @notice Cancels an invoice
     * @param claimId The ID of the invoice to cancel
     * @param note The note to cancel the invoice with
     */
    function cancelInvoice(uint256 claimId, string memory note) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.cancelClaimFrom(msg.sender, claimId, note);
    }

    /**
     * @notice Burns an invoice
     * @param tokenId The ID of the invoice to burn
     */
    function burn(uint256 tokenId) external {
        Claim memory claim = _bullaClaim.getClaim(tokenId);
        _checkController(claim.controller);

        return _bullaClaim.burn(tokenId);
    }

    /// PRIVATE FUNCTIONS ///

    /**
     * @notice Validates the parameters for creating an invoice
     * @param params The parameters for creating an invoice
     */
    function _validateCreateInvoiceParams(CreateInvoiceParams memory params) private view {
        if (params.dueBy != 0 && (params.dueBy < block.timestamp || params.dueBy > type(uint40).max)) {
            revert InvalidDueBy();
        }
    }
}
