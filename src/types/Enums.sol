//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

enum Status {
    Pending, // default status: 0 is pending
    Repaying, // status for a claim that is not fully paid, but some payment amount > 0 has been made
    Paid, // status for a claim that is fully paid
    Rejected, // status reserved for the debtor to close out a claim
    Rescinded // status reserved for the creditor to close out a claim
}

enum ClaimBinding {
    Unbound, // default binding: 0 is unbound
    BindingPending, // a way for the creditor to signal that they want a debtor to accept a claim
    Bound // bound status is when the debtor has accepted the claim
}

enum FeePayer {
    Creditor,
    Debtor
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
