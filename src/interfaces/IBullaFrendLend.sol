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
    uint128 loanAmount;
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
    bool payerReceivesClaimOnPayment;
    address debtor;
    address token;
    address controller;
    uint256 dueBy;
    uint256 acceptedAt;
    InterestConfig interestConfig;
    InterestComputationState interestComputationState;
}

/**
 * @title IBullaFrendLend
 * @notice Interface for BullaFrendLend contract functionality
 */
interface IBullaFrendLend {
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
    function payLoan(uint256 claimId, uint256 paymentAmount) external;
    function impairLoan(uint256 claimId) external;
    function markLoanAsPaid(uint256 claimId) external;

    // Admin functions
    function withdrawAllFees() external;
    function setProtocolFee(uint256 _protocolFeeBPS) external;

    // State variables
    function admin() external view returns (address);

    function loanOfferCount() external view returns (uint256);
    function protocolFeeBPS() external view returns (uint256);
    function getLoanOffer(uint256) external view returns (LoanOffer memory);
    function getLoanOfferMetadata(uint256) external view returns (ClaimMetadata memory);
    function protocolFeesByToken(address token) external view returns (uint256);
}
