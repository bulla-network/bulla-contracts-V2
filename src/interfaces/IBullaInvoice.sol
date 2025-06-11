// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "../types/Types.sol";
import "../libraries/CompoundInterestLib.sol";

// Forward declarations to avoid import cycles
struct Invoice {
    uint256 claimAmount;
    uint256 paidAmount;
    uint256 dueBy;
    address creditor;
    address debtor;
    address token;
    Status status;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
    PurchaseOrderState purchaseOrder;
    InterestConfig lateFeeConfig;
    InterestComputationState interestComputationState;
}

struct PurchaseOrderState {
    uint256 deliveryDate;
    uint256 depositAmount;
    bool isDelivered;
}

// Directionality is determined by the function that calls it
struct CreateInvoiceParams {
    address recipient;
    uint256 claimAmount;
    uint256 dueBy;
    uint256 deliveryDate;
    string description;
    address token;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
    InterestConfig lateFeeConfig;
    uint256 impairmentGracePeriod;
    uint256 depositAmount;
}

/**
 * @title IBullaInvoice
 * @notice Interface for BullaInvoice contract functionality
 */
interface IBullaInvoice {
    // Main invoice functions
    function createInvoice(CreateInvoiceParams memory params) external payable returns (uint256);
    function createInvoiceWithMetadata(CreateInvoiceParams memory params, ClaimMetadata memory metadata)
        external
        payable
        returns (uint256);
    function getInvoice(uint256 claimId) external view returns (Invoice memory);
    function payInvoice(uint256 claimId, uint256 paymentAmount) external payable;
    function deliverPurchaseOrder(uint256 claimId) external;
    function acceptPurchaseOrder(uint256 claimId, uint256 depositAmount) external payable;

    // Purchase order functions
    function getTotalAmountNeededForPurchaseOrderDeposit(uint256 claimId) external returns (uint256);

    // Claim management functions
    function updateBinding(uint256 claimId, ClaimBinding binding) external;
    function cancelInvoice(uint256 claimId, string memory note) external;

    // Admin functions
    function setProtocolFee(uint256 _protocolFeeBPS) external;
    function withdrawAllFees() external;

    // View functions
    function admin() external view returns (address);
    function protocolFeeBPS() external view returns (uint256);
    function invoiceOriginationFee() external view returns (uint256);
    function purchaseOrderOriginationFee() external view returns (uint256);
    function protocolFeesByToken(address token) external view returns (uint256);
}
