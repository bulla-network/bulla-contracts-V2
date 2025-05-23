// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/BullaClaimControllerBase.sol";
import "contracts/types/Types.sol";
import "contracts/libraries/CompoundInterestLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

struct PurchaseOrderState {
    uint256 deliveryDate; // 0 if not a purchase order
    bool isDelivered; // false = is still a purchase order, true = is invoice
}

// Data specific to invoices and not claims
struct InvoiceDetails {
    uint256 dueBy;
    PurchaseOrderState purchaseOrder;
    InterestConfig lateFeeConfig;
    InterestComputationState interestComputationState;
}

error InvalidDueBy();
error CreditorCannotBeDebtor();
error InvalidDeliveryDate();
error NotOriginalCreditor();
error PurchaseOrderAlreadyDelivered();
error InvoiceNotPending();
error NotPurchaseOrder();
error PayingZero();

struct Invoice {
    uint256 claimAmount;
    uint256 paidAmount;
    Status status;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
    address debtor;
    address token;
    uint256 dueBy;
    PurchaseOrderState purchaseOrder;
    InterestConfig lateFeeConfig;
    InterestComputationState interestComputationState;
    InterestConfig interestConfig;
}

struct CreateInvoiceParams {
    address debtor;
    uint256 claimAmount;
    uint256 dueBy;
    uint256 deliveryDate;
    string description;
    address token;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
    InterestConfig lateFeeConfig;
}

/**
 * @title BullaInvoice
 * @notice A wrapper contract for IBullaClaim that delegates all calls to the provided contract instance
 */
contract BullaInvoice is BullaClaimControllerBase {
    using SafeTransferLib for address;
    using SafeTransferLib for ERC20;

    mapping(uint256 => InvoiceDetails) private _invoiceDetailsByClaimId;

    event InvoiceCreated(uint256 claimId, uint256 dueBy);
    event InvoicePaid(uint256 claimId, uint256 interestPaid);
    
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
        
        if ((claim.status == Status.Pending || claim.status == Status.Repaying) && 
            invoiceDetails.lateFeeConfig.interestRateBps > 0) {

            // Refresh interest calculation
            uint256 unpaidPrincipal = claim.claimAmount - claim.paidAmount;
            if (unpaidPrincipal > 0) {
                invoiceDetails.interestComputationState = CompoundInterestLib.computeInterest(
                    unpaidPrincipal,
                    invoiceDetails.dueBy,
                    invoiceDetails.interestComputationState.latestPeriodNumber,
                    invoiceDetails.lateFeeConfig, 
                    invoiceDetails.interestComputationState
                );
            }
        }

        return Invoice({
            claimAmount: claim.claimAmount,
            paidAmount: claim.paidAmount,
            status: claim.status,
            binding: claim.binding,
            payerReceivesClaimOnPayment: claim.payerReceivesClaimOnPayment,
            debtor: claim.debtor,
            token: claim.token,
            dueBy: invoiceDetails.dueBy,
            purchaseOrder: invoiceDetails.purchaseOrder,
            lateFeeConfig: invoiceDetails.lateFeeConfig,
            interestComputationState: invoiceDetails.interestComputationState,
            interestConfig: invoiceDetails.lateFeeConfig
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
            creditor: msg.sender,
            debtor: params.debtor,
            claimAmount: params.claimAmount,
            description: params.description,
            token: params.token,
            binding: params.binding,
            payerReceivesClaimOnPayment: params.payerReceivesClaimOnPayment
        });

        uint256 claimId = _bullaClaim.createClaimFrom(msg.sender, createClaimParams);

        _invoiceDetailsByClaimId[claimId] = InvoiceDetails({
            dueBy: params.dueBy, 
            purchaseOrder: PurchaseOrderState({
                deliveryDate: params.deliveryDate, 
                isDelivered: false
            }),
            lateFeeConfig: params.lateFeeConfig,
            interestComputationState: InterestComputationState({
                accruedInterest: 0,
                latestPeriodNumber: 0
            })
        });

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
            creditor: msg.sender,
            debtor: params.debtor,
            claimAmount: params.claimAmount,
            description: params.description,
            token: params.token,
            binding: params.binding,
            payerReceivesClaimOnPayment: params.payerReceivesClaimOnPayment
        });

        uint256 claimId = _bullaClaim.createClaimWithMetadataFrom(msg.sender, createClaimParams, metadata);

        _invoiceDetailsByClaimId[claimId] =
            InvoiceDetails({
                dueBy: params.dueBy, 
                purchaseOrder: PurchaseOrderState({deliveryDate: params.deliveryDate, isDelivered: false}), 
                lateFeeConfig: params.lateFeeConfig,    
                interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0})});

        emit InvoiceCreated(claimId, params.dueBy);

        return claimId;
    }

    function deliverPurchaseOrder(uint256 claimId) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        if (claim.originalCreditor != msg.sender) {
            revert NotOriginalCreditor();
        }

        if (invoiceDetails.purchaseOrder.deliveryDate == 0) {
            revert NotPurchaseOrder();
        }

        if (invoiceDetails.purchaseOrder.isDelivered) {
            revert PurchaseOrderAlreadyDelivered();
        }

        if (claim.status != Status.Pending && claim.status != Status.Repaying) {
            revert InvoiceNotPending();
        }


        _invoiceDetailsByClaimId[claimId].purchaseOrder.isDelivered = true;
    }

    /**
     * @notice Pays an invoice and updates interest before processing the payment
     * @param claimId The ID of the invoice to pay
     * @param paymentAmount The amount to pay
     */
    function payInvoice(uint256 claimId, uint256 paymentAmount) external payable {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        InterestComputationState memory interestComputationState = CompoundInterestLib.computeInterest(
            claim.claimAmount - claim.paidAmount,
            invoiceDetails.dueBy,
            invoiceDetails.interestComputationState.latestPeriodNumber,
            invoiceDetails.lateFeeConfig,
            invoiceDetails.interestComputationState);

        uint256 totalInterestBeingPaid = Math.min(paymentAmount, interestComputationState.accruedInterest);
        uint256 principalBeingPaid = Math.min(paymentAmount - totalInterestBeingPaid, claim.claimAmount - claim.paidAmount);
        paymentAmount = principalBeingPaid + totalInterestBeingPaid;

        if (paymentAmount == 0) {
            revert PayingZero();
        }

        // need to check this because calling bulla claim since it might transfer the claim to the creditor if `payerReceivesClaimOnPayment` is true
        address creditor = _bullaClaim.ownerOf(claimId);

        if (principalBeingPaid > 0) {
            _bullaClaim.payClaimFromControllerWithoutTransfer(msg.sender, claimId, principalBeingPaid);
        }

        // Update interest computation state
        if (invoiceDetails.lateFeeConfig.interestRateBps > 0) {
            _invoiceDetailsByClaimId[claimId].interestComputationState = InterestComputationState({
                accruedInterest: interestComputationState.accruedInterest - totalInterestBeingPaid,
                latestPeriodNumber: interestComputationState.latestPeriodNumber
            });
        }

        if (paymentAmount > 0) {
            // TODO: if protocol fee, will need two transfers, like frendlend
            claim.token == address(0) ? 
                creditor.safeTransferETH(paymentAmount)
                : ERC20(claim.token).safeTransferFrom(msg.sender, creditor, paymentAmount);

            // TODO: protocol fee much like in Frendlend

            if (totalInterestBeingPaid > 0) {
                emit InvoicePaid(claimId, totalInterestBeingPaid);
            }
        }
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

    /// PRIVATE FUNCTIONS ///

    /**
     * @notice Validates the parameters for creating an invoice
     * @param params The parameters for creating an invoice
     */
    function _validateCreateInvoiceParams(CreateInvoiceParams memory params) private view {
        if (msg.sender == params.debtor) {
            revert CreditorCannotBeDebtor();
        }
        
        if (params.dueBy != 0 && (params.dueBy < block.timestamp || params.dueBy > type(uint40).max)) {
            revert InvalidDueBy();
        }

        if (params.deliveryDate != 0 && (params.deliveryDate < block.timestamp || params.deliveryDate > type(uint40).max)) {
            revert InvalidDeliveryDate();
        }

        CompoundInterestLib.validateInterestConfig(params.lateFeeConfig);
    }
}
