// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/types/Types.sol";

// Data specific to invoices and not claims
struct InvoiceDetails {
    uint256 dueBy;
}

error InvoiceDoesNotExist(uint256 claimId);
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
    address controller;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
}

/**
 * @title BullaInvoice
 * @notice A wrapper contract for IBullaClaim that delegates all calls to the provided contract instance
 */
contract BullaInvoice {
    IBullaClaim private immutable _bullaClaim;

    // Track all claim IDs created through this contract
    uint256[] private _createdClaimIds;
    mapping(uint256 => bool) private _isClaimCreatedHere;
    mapping(uint256 => InvoiceDetails) private _invoiceDetailsByClaimId;

    /**
     * @notice Constructor
     * @param bullaClaim Address of the IBullaClaim contract to delegate calls to
     */
    constructor(address bullaClaim) {
        _bullaClaim = IBullaClaim(bullaClaim);
    }

    function getInvoice(uint256 claimId) external view returns (Invoice memory) {
        if (_isClaimCreatedHere[claimId]) {
            Claim memory claim = _bullaClaim.getClaim(claimId);
            InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];
            return Invoice({
                claimAmount: claim.claimAmount,
                paidAmount: claim.paidAmount,
                status: claim.status,
                binding: claim.binding,
                payerReceivesClaimOnPayment: claim.payerReceivesClaimOnPayment,
                debtor: claim.debtor,
                dueBy: claim.dueBy,
                token: claim.token,
                dueBy: invoiceDetails.dueBy
            });
        }

        revert InvoiceDoesNotExist(claimId);
    }

    function createInvoice(CreateInvoiceParams memory params) external returns (uint256) {
        _validateCreateInvoiceParams(params);

        uint256 claimId = _bullaClaim.createClaimFrom(msg.sender, params);
        _recordCreatedClaim(claimId);

        return claimId;
    }

    function createInvoiceWithMetadata(CreateInvoiceParams memory params, ClaimMetadata memory metadata)
        external
        returns (uint256)
    {
        _validateCreateInvoiceParams(params);

        uint256 claimId = _bullaClaim.createClaimWithMetadataFrom(msg.sender, params, metadata);
        _recordCreatedClaim(claimId);

        return claimId;
    }

    function payClaim(uint256 claimId, uint256 amount) external payable {
        _bullaClaim.payClaimFrom{value: msg.value}(msg.sender, claimId, amount);
    }

    function updateBinding(uint256 claimId, uint8 binding) external {
        _bullaClaim.updateBindingFrom(msg.sender, claimId, binding);
    }

    function cancelClaim(uint256 claimId, string memory note) external {
        _bullaClaim.cancelClaimFrom(msg.sender, claimId, note);
    }

    function burn(uint256 tokenId) external {
        _bullaClaim.burn(tokenId);
    }

    /**
     * @notice Records a claim ID as created through this contract
     * @param claimId The ID of the claim that was created
     */
    function _recordCreatedClaim(uint256 claimId) private {
        if (!_isClaimCreatedHere[claimId]) {
            _createdClaimIds.push(claimId);
            _isClaimCreatedHere[claimId] = true;
        }
    }

    /**
     * @notice Get all claim IDs created through this contract
     * @return Array of claim IDs
     */
    function getCreatedClaimIds() external view returns (uint256[] memory) {
        return _createdClaimIds;
    }

    /**
     * @notice Check if a claim was created through this contract
     * @param claimId The ID of the claim to check
     * @return True if the claim was created through this contract
     */
    function isClaimCreatedHere(uint256 claimId) external view returns (bool) {
        return _isClaimCreatedHere[claimId];
    }

    /**
     * @notice Get the total number of claims created through this contract
     * @return The number of claims created
     */
    function getCreatedClaimCount() external view returns (uint256) {
        return _createdClaimIds.length;
    }

    function _validateCreateInvoiceParams(CreateInvoiceParams memory params) private {
        if (params.dueBy != 0 && (params.dueBy < block.timestamp || params.dueBy > type(uint40).max)) {
            revert InvalidDueBy();
        }
    }
}
