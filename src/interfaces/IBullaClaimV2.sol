// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./IBullaClaimCore.sol";
import "./IBullaClaimAdmin.sol";

interface IBullaClaimV2 is IBullaClaimCore, IBullaClaimAdmin {
    /*///////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error Locked();
    error PastApprovalDeadline();
    error NotOwner();
    error NotController(address sender);
    error ClaimPending();
    error NotMinted();
    error PaymentUnderApproved();
    error WithdrawalFailed();
    error InvalidInterface();
    error IncorrectFee();
    error CannotBindClaim();
    error NotCreditorOrDebtor();
    error NotCreditor();
    error ClaimBound();
    error ClaimNotPending();
    error NotApproved();
    error PayingZero();
    error OverPaying(uint256 paymentAmount);
    error ApprovalExpired();
    error NotSupported();
    error MustBeControlledClaim();

    /*///////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        uint256 dueBy,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    event MetadataAdded(uint256 indexed claimId, string tokenURI, string attachmentURI);

    event ClaimPayment(uint256 indexed claimId, address indexed paidBy, uint256 paymentAmount, uint256 totalPaidAmount);

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

    event ClaimRejected(uint256 indexed claimId, address indexed from, string note);

    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    event ClaimImpaired(uint256 indexed claimId);

    event ClaimMarkedAsPaid(uint256 indexed claimId);
}
