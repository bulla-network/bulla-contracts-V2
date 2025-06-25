// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./types/Types.sol";

/**
 * @title BaseBullaClaim
 * @dev Abstract base contract containing events and errors for BullaClaim
 * @notice This contract is used to reduce the main contract size by extracting events and errors
 */
abstract contract BaseBullaClaim {
    /*///////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error Locked();
    error InvalidApproval();
    error InvalidSignature();
    error PastApprovalDeadline();
    error NotOwner();
    error NotController(address sender);
    error ClaimPending();
    error NotMinted();
    error PaymentUnderApproved();
    error WithdrawalFailed();
    error InvalidInterface();
    error IncorrectFee();

    /*///////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
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

    event FeeWithdrawn(address indexed owner, uint256 amount);
}
