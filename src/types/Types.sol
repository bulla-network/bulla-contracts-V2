// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

////// ENUMS //////

enum Status {
    Pending, // default status is pending
    Repaying, // status for a claim where 0 < paid amount < claim amount
    Paid, // status for a claim that is fully paid
    Rejected, // status reserved for the debtor to cancel a claim
    Rescinded, // status reserved for the creditor to cancel a claim
    Impaired // status reserved for the creditor to mark a claim as impaired

}

enum ClaimBinding {
    Unbound, // default binding is unbound
    BindingPending, // a way for the creditor to signal that they want a debtor to accept a claim
    Bound // bound status is when the debtor has accepted the claim

}

enum CreateClaimApprovalType {
    Unapproved,
    CreditorOnly, // an addresss is allowed only to create claims where the user is the creditor
    DebtorOnly, // an addresss is allowed only to create claims where the user is the debtor
    Approved // an addresss is allowed to create any kind of claim

}

enum PayClaimApprovalType {
    Unapproved,
    IsApprovedForSpecific,
    IsApprovedForAll
}

enum LockState {
    Unlocked,
    NoNewClaims, // an intermediary state where we allow users to pay, reject, rescind, and accept claims, but disallow new claims to be made
    Locked
}

////// STRUCTS //////

struct CreateClaimParams {
    address creditor;
    address debtor;
    uint256 claimAmount;
    string description;
    address token;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
    uint256 dueBy;
    uint256 impairmentGracePeriod; // seconds after dueBy that claim cannot be impaired
}

struct ClaimMetadata {
    string tokenURI;
    string attachmentURI;
}

struct ClaimStorage {
    uint128 claimAmount;
    uint128 paidAmount;
    address originalCreditor;
    address debtor;
    address token; // the token address that the claim is denominated in. NOTE: if this token is address(0), we treat this as a native token
    address controller;
    Status status;
    ClaimBinding binding; // the debtor can allow themselves to be bound to a claim, which makes a claim unrejectable
    bool payerReceivesClaimOnPayment; // an optional flag which allows the token to be transferred to the payer, acting as a "receipt NFT"
    uint40 dueBy; // when the claim is due (0 means no due date)
    uint40 impairmentGracePeriod; // seconds after dueBy that claim cannot be impaired
} // takes 5 storage slots

// a cheaper struct for working / manipulating memory (unpacked is cheapter)
struct Claim {
    uint256 claimAmount;
    uint256 paidAmount;
    uint256 dueBy;
    uint256 impairmentGracePeriod;
    address originalCreditor;
    address debtor;
    address creditor;
    address token;
    address controller;
    Status status;
    ClaimBinding binding;
    bool payerReceivesClaimOnPayment;
}

////// APPROVALS //////

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

struct UpdateBindingApproval {
    uint64 approvalCount;
    uint64 nonce;
}

struct CancelClaimApproval {
    uint64 approvalCount;
    uint64 nonce;
}

struct ImpairClaimApproval {
    uint64 approvalCount;
    uint64 nonce;
}

struct MarkAsPaidApproval {
    uint64 approvalCount;
    uint64 nonce;
}

struct Approvals {
    CreateClaimApproval createClaim;
    PayClaimApproval payClaim;
    UpdateBindingApproval updateBinding;
    CancelClaimApproval cancelClaim;
    ImpairClaimApproval impairClaim;
    MarkAsPaidApproval markAsPaid;
}
