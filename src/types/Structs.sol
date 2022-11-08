//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {
    Status, ClaimBinding, FeePayer, CreateClaimApprovalType, PayClaimApprovalType
} from "contracts/types/Enums.sol";

struct Signature {
    bytes32 r;
    bytes32 s;
    uint8 v;
}

struct ClaimMetadata {
    string tokenURI;
    string attachmentURI;
}

struct ClaimStorage {
    uint128 claimAmount;
    uint128 paidAmount;
    Status status;
    ClaimBinding binding; // the debtor can allow themselves to be bound to a claim, which makes a claim unrejectable
    FeePayer feePayer;
    // if feePayer = Debtor:
    //      the payer is charged the fee and the creditor receives the _exact_ amount listed on the claim.
    // if feePayer = Creditor:
    //      the creditor pays the fee, meaning they will receive claimAmount - fee
    uint16 feeCalculatorId;
    uint40 dueBy;
    address debtor;
    address token; // the token address that the claim is denominated in. NOTE: if this token is address(0), we treat this as a native token
    address delegator;
} // takes 4 storage slots

// a cheaper struct for working / manipulating memory (unpacked is cheapter)
struct Claim {
    uint256 claimAmount;
    uint256 paidAmount;
    Status status;
    ClaimBinding binding;
    FeePayer feePayer;
    address debtor;
    uint256 feeCalculatorId;
    uint256 dueBy;
    address token;
    address delegator;
}

struct CreateClaimApproval {
    bool isBindingAllowed;
    CreateClaimApprovalType approvalType;
    uint64 approvalCount; // the amount the contract can call this function for the user, type(uint64).max implies unlimited
    uint64 nonce; // the nonce for the approval - only incremented per approval update.
}

struct ClaimPaymentApprovalParam {
    uint256 claimId;
    uint256 approvalDeadline;
    uint256 approvedAmount;
}

// a compact 1 slot representation of a claim payment approval
struct ClaimPaymentApproval {
    uint88 claimId;
    uint40 approvalDeadline;
    uint128 approvedAmount;
}

struct PayClaimApproval {
    PayClaimApprovalType approvalType;
    uint40 approvalDeadline;
    uint64 nonce;
    ClaimPaymentApproval[] claimApprovals;
}

struct Approvals {
    CreateClaimApproval createClaim;
    PayClaimApproval payClaim;
}
