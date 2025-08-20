// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "../types/Types.sol";
import "../libraries/CompoundInterestLib.sol";

// Forward declarations to avoid import cycles
struct LoanDetails {
    uint256 acceptedAt;
    InterestConfig interestConfig;
    InterestComputationState interestComputationState;
    bool isProtocolFeeExempt;
}

struct LoanRequestParams {
    uint256 termLength;
    InterestConfig interestConfig;
    uint256 loanAmount;
    address creditor;
    address debtor;
    string description;
    address token;
    uint256 impairmentGracePeriod;
    uint256 expiresAt; // timestamp when the offer expires (0 = no expiry)
    address callbackContract; // contract to call when loan is accepted (0 = no callback)
    bytes4 callbackSelector; // function selector to call on callback contract
}

struct LoanOffer {
    LoanRequestParams params;
    bool requestedByCreditor;
}

struct Loan {
    uint256 claimAmount;
    uint256 paidAmount;
    Status status;
    ClaimBinding binding;
    address debtor;
    address creditor;
    address token;
    address controller;
    uint256 dueBy;
    uint256 acceptedAt;
    InterestConfig interestConfig;
    InterestComputationState interestComputationState;
}

/**
 * @title IBullaFrendLendV2
 * @notice Interface for BullaFrendLendV2 contract functionality
 */
interface IBullaFrendLendV2 {
    // View functions
    function getTotalAmountDue(uint256 claimId) external view returns (uint256 remainingPrincipal, uint256 interest);
    function getLoan(uint256 claimId) external view returns (Loan memory);

    // Offer functions
    function offerLoanWithMetadata(LoanRequestParams calldata offer, ClaimMetadata calldata metadata)
        external
        returns (uint256);
    function offerLoan(LoanRequestParams calldata offer) external returns (uint256);

    // Core functions
    function rejectLoanOffer(uint256 offerId) external;
    function acceptLoan(uint256 offerId) external payable returns (uint256);
    function acceptLoanWithReceiver(uint256 offerId, address receiver) external payable returns (uint256);
    function batchAcceptLoans(uint256[] calldata offerIds) external payable;
    function payLoan(uint256 claimId, uint256 paymentAmount) external;
    function impairLoan(uint256 claimId) external;
    function markLoanAsPaid(uint256 claimId) external;

    // Admin functions
    function withdrawAllFees() external;
    function setProtocolFee(uint16 _protocolFeeBPS) external;
    function addToFeeTokenWhitelist(address token) external;
    function removeFromFeeTokenWhitelist(address token) external;

    // State variables
    function admin() external view returns (address);

    function loanOfferCount() external view returns (uint256);
    function protocolFeeBPS() external view returns (uint16);
    function getLoanOffer(uint256) external view returns (LoanOffer memory);
    function getLoanOfferMetadata(uint256) external view returns (ClaimMetadata memory);
    function protocolFeesByToken(address token) external view returns (uint256);

    /*///////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event LoanOffered(
        uint256 indexed offerId, address indexed offeredBy, LoanRequestParams loanOffer, ClaimMetadata metadata
    );
    event LoanOfferAccepted(uint256 indexed offerId, uint256 indexed claimId, uint256 fee, ClaimMetadata metadata);
    event LoanOfferRejected(uint256 indexed offerId, address indexed rejectedBy);
    /// @notice grossInterestPaid = interest received by creditor + protocolFee
    event LoanPayment(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);
    event ProtocolFeeUpdated(uint16 oldFee, uint16 newFee);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);
    event TokenAddedToFeesWhitelist(address indexed token);
    event TokenRemovedFromFeesWhitelist(address indexed token);
}
