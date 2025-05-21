// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/BullaClaimControllerBase.sol";
import "contracts/types/Types.sol";
import "contracts/libraries/CompoundInterestLib.sol";

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
error InvalidInterestConfig();
error NotAuthorizedToConfigureInterest();

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
    InterestConfig interestConfig;
}

/**
 * @title BullaInvoice
 * @notice A wrapper contract for IBullaClaim that delegates all calls to the provided contract instance
 */
contract BullaInvoice is BullaClaimControllerBase {
    mapping(uint256 => InvoiceDetails) private _invoiceDetailsByClaimId;

    event InvoiceCreated(uint256 claimId, uint256 dueBy);
    event InterestConfigured(uint256 claimId, uint16 interestRateBps, uint16 periodsPerYear);
    event InterestAccrued(uint256 claimId, uint256 interestAmount, uint256 newTotalDue);

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
            block.timestamp > invoiceDetails.interestComputationState.lastAccrualTimestamp && 
            invoiceDetails.interestConfig.interestRateBps > 0) {

            // Refresh interest calculation
            uint256 unpaidPrincipal = claim.claimAmount - claim.paidAmount;
            if (unpaidPrincipal > 0) {
                invoiceDetails.interestComputationState = CompoundInterestLib.computeInterest(
                    unpaidPrincipal,
                    invoiceDetails.dueBy,
                    invoiceDetails.interestConfig, 
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
            interestConfig: invoiceDetails.interestConfig
        });
    }

    /**
     * @notice Creates an invoice
     * @param params The parameters for creating an invoice
     * @return The ID of the created invoice
     */
    function createInvoice(CreateInvoiceParams memory params) external returns (uint256) {
        _validateCreateInvoiceParams(params);
        _validateInterestConfig(params.interestConfig);

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
                lastAccrualTimestamp: params.dueBy
            })
        });
        
        // Store interest configuration if specified
        if (params.interestConfig.interestRateBps > 0) {
            _interestConfigByClaimId[claimId] = params.interestConfig;
            _interestStateByClaimId[claimId] = InterestComputationState({
                accruedInterest: 0,
                lastAccrualTimestamp: params.dueBy
            });
            
            emit InterestConfigured(
                claimId, 
                params.interestConfig.interestRateBps, 
                params.interestConfig.numberOfPeriodsPerYear
            );
        }

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
                interestComputationState: InterestComputationState({accruedInterest: 0, lastAccrualTimestamp: params.dueBy})});

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
     * @param amount The amount to pay
     */
    function payInvoice(uint256 claimId, uint256 amount) external payable {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);
        
        // Update interest before payment
        uint256 newInterest = updateInterest(claimId);
        
        // If there's interest accrued, include it in the payment amount
        // Since we can't modify the claim amount directly, 
        // we need to ensure the payment covers both principal and accrued interest
        uint256 totalDue = claim.claimAmount;
        
        if (state.accruedInterest > 0) {
            // Calculate total amount due including interest
            totalDue += state.accruedInterest;
            
            // If paying less than total, adjust based on proportions
            if (amount < totalDue && amount > 0) {
                uint256 principalPayment = (amount * claim.claimAmount) / totalDue;
                uint256 interestPayment = amount - principalPayment;
                
                // Reduce tracked interest by interest payment
                if (interestPayment > 0 && interestPayment <= state.accruedInterest) {
                    _interestStateByClaimId[claimId].accruedInterest -= interestPayment;
                    
                    // We only send the principal portion to the underlying claim
                    amount = principalPayment;
                }
            } else if (amount >= totalDue) {
                // If paying in full, reset interest state
                _interestStateByClaimId[claimId].accruedInterest = 0;
            }
        }
        
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
     * @notice Configure interest parameters for an invoice
     * @param claimId The ID of the invoice to configure
     * @param config The interest configuration
     */
    function configureInterest(uint256 claimId, InterestConfig memory config) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);
        
        // Only the original creditor can configure interest
        if (claim.originalCreditor != msg.sender) {
            revert NotAuthorizedToConfigureInterest();
        }
        
        // Validate the new config
        _validateInterestConfig(config);
        
        // Update the interest configuration
        _interestConfigByClaimId[claimId] = config;
        
        // Reset computation state if changing configuration
        if (config.interestRateBps > 0) {
            InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];
            
            _interestStateByClaimId[claimId] = InterestComputationState({
                accruedInterest: _interestStateByClaimId[claimId].accruedInterest,
                lastAccrualTimestamp: block.timestamp > invoiceDetails.dueBy ? 
                    block.timestamp : invoiceDetails.dueBy
            });
        }
        
        emit InterestConfigured(claimId, config.interestRateBps, config.numberOfPeriodsPerYear);
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

        if (params.lateFeeConfig.interestRateBps != 0) {
            if (params.lateFeeConfig.numberOfPeriodsPerYear == 0 || params.lateFeeConfig.numberOfPeriodsPerYear > MAX_DAYS_PER_YEAR) {
                revert InvalidPeriodsPerYear();
            }
        }
    }

    /**
     * @notice Validates interest configuration
     * @param config The interest configuration to validate
     */
    function _validateInterestConfig(InterestConfig memory config) private pure {
        // Skip validation if interest is disabled
        if (config.interestRateBps == 0) {
            return;
        }
        
        // Validate periods per year (daily max)
        if (config.numberOfPeriodsPerYear == 0 || config.numberOfPeriodsPerYear > 365) {
            revert InvalidInterestConfig();
        }
        
        // Max rate validation (100% APR)
        if (config.interestRateBps > 10000) {
            revert InvalidInterestConfig();
        }
    }
}
