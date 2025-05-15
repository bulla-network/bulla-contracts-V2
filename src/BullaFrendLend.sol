// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/BullaClaimControllerBase.sol";
import "contracts/types/Types.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

uint256 constant MAX_BPS = 10_000;

error IncorrectFee();
error NotCreditor();
error NotDebtor();
error NotCreditorOrDebtor();
error NotAdmin();
error InvalidTermLength();
error WithdrawalFailed();
error TransferFailed();
error LoanOfferNotFound();
error NativeTokenNotSupported();

struct LoanDetails {
    uint256 dueBy;        
    uint24 interestBPS;    
    uint40 termLength;    
}

struct LoanOffer {
    uint24 interestBPS;    // can be 0
    uint40 termLength;     // cannot be 0
    uint128 loanAmount;    
    address creditor;      
    address debtor;        
    string description;    
    address token;         
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
    uint24 interestBPS;
    uint40 termLength;
}

/**
 * @title BullaFrendLend
 * @notice A wrapper contract for IBullaClaim that allows creditors to offer loans that debtors can accept
 */
contract BullaFrendLend is BullaClaimControllerBase {
    address public admin;
    uint256 public fee;
    uint256 public loanOfferCount;
    
    mapping(uint256 => LoanOffer) public loanOffers;
    mapping(uint256 => LoanDetails) private _loanDetailsByClaimId;

    event LoanOffered(uint256 indexed loanId, address indexed offeredBy, LoanOffer loanOffer, uint256 blocktime);
    event LoanOfferAccepted(uint256 indexed loanId, uint256 indexed claimId, uint256 blocktime);
    event LoanOfferRejected(uint256 indexed loanId, address indexed rejectedBy, uint256 blocktime);
    event LoanPayment(uint256 indexed claimId, uint256 interestPayment, uint256 principalPayment, uint256 blocktime);

    /**
     * @param bullaClaim Address of the IBullaClaim contract to delegate calls to
     * @param _admin Address of the contract administrator
     * @param _fee Fee required to create a loan offer
     */
    constructor(address bullaClaim, address _admin, uint256 _fee) BullaClaimControllerBase(bullaClaim) {
        admin = _admin;
        fee = _fee;
    }

    /**
     * @notice Calculate the current interest amount for a loan
     * @param claimId The ID of the loan
     * @return The current interest amount
     */
    function calculateCurrentInterest(uint256 claimId) public view returns (uint256) {
        LoanDetails memory loanDetails = _loanDetailsByClaimId[claimId];
        Claim memory claim = _bullaClaim.getClaim(claimId);
        
        // Calculate time elapsed in seconds
        uint256 timeElapsed = block.timestamp - (loanDetails.dueBy - loanDetails.termLength);
        
        // Calculate interest: principal * interestBPS * timeElapsed / (MAX_BPS * termLength)
        return (claim.claimAmount * loanDetails.interestBPS * timeElapsed) / (MAX_BPS * loanDetails.termLength);
    }

    /**
     * @notice Get the total amount due for a loan including principal and interest
     * @param claimId The ID of the loan
     * @return remainingPrincipal The remaining principal amount due
     * @return interest The current interest amount accrued
     */
    function getTotalAmountDue(uint256 claimId) public view returns (uint256 remainingPrincipal, uint256 interest) {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        remainingPrincipal = claim.claimAmount - claim.paidAmount;
        interest = calculateCurrentInterest(claimId);
    }

    /**
     * @notice Get a loan with all its details
     * @param claimId The ID of the claim associated with the loan
     * @return The loan details
     */
    function getLoan(uint256 claimId) external view returns (Loan memory) {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);
        
        LoanDetails memory loanDetails = _loanDetailsByClaimId[claimId];
        
        return Loan({
            claimAmount: claim.claimAmount,
            paidAmount: claim.paidAmount,
            status: claim.status,
            binding: claim.binding,
            payerReceivesClaimOnPayment: claim.payerReceivesClaimOnPayment,
            debtor: claim.debtor,
            token: claim.token,
            controller: claim.controller,
            dueBy: loanDetails.dueBy,
            interestBPS: loanDetails.interestBPS,
            termLength: loanDetails.termLength
        });
    }

    /**
     * @notice Allows a user to create and offer a loan to a potential debtor
     * @param offer The loan offer parameters
     * @return The ID of the created loan offer
     */
    function offerLoan(LoanOffer calldata offer) external payable returns (uint256) {
        if (msg.value != fee) revert IncorrectFee();
        if (msg.sender != offer.creditor) revert NotCreditor();
        if (offer.termLength == 0) revert InvalidTermLength();
        if (offer.token == address(0)) revert NativeTokenNotSupported();

        uint256 offerId = ++loanOfferCount;
        loanOffers[offerId] = offer;

        emit LoanOffered(offerId, msg.sender, offer, block.timestamp);

        return offerId;
    }

    /**
     * @notice Allows a debtor or creditor to reject or rescind a loan offer
     * @param offerId The ID of the loan offer to reject
     */
    function rejectLoanOffer(uint256 offerId) external {
        LoanOffer memory offer = loanOffers[offerId];
        
        if (offer.creditor == address(0)) revert LoanOfferNotFound();
        if (msg.sender != offer.creditor && msg.sender != offer.debtor) revert NotCreditorOrDebtor();

        delete loanOffers[offerId];

        emit LoanOfferRejected(offerId, msg.sender, block.timestamp);
    }

    /**
     * @notice Allows a debtor to accept a loan offer and receive payment
     * @param offerId The ID of the loan offer to accept
     * @param metadata Optional metadata for the claim
     * @return The ID of the created claim
     */
    function acceptLoan(uint256 offerId, ClaimMetadata calldata metadata) external returns (uint256) {
        LoanOffer memory offer = loanOffers[offerId];
        
        if (offer.creditor == address(0)) revert LoanOfferNotFound();
        if (msg.sender != offer.debtor) revert NotDebtor();

        delete loanOffers[offerId];

        CreateClaimParams memory claimParams = CreateClaimParams({
            creditor: offer.creditor,
            debtor: offer.debtor,
            claimAmount: offer.loanAmount,
            description: offer.description,
            token: offer.token,
            binding: ClaimBinding.Bound, // Loans are bound claims, avoiding the 1 wei transfer used in V1
            payerReceivesClaimOnPayment: true
        });

        // Create the claim via BullaClaim
        uint256 claimId;
        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            claimId = _bullaClaim.createClaimWithMetadataFrom(msg.sender, claimParams, metadata);
        } else {
            claimId = _bullaClaim.createClaimFrom(msg.sender, claimParams);
        }

        _loanDetailsByClaimId[claimId] = LoanDetails({
            dueBy: block.timestamp + offer.termLength,
            interestBPS: offer.interestBPS,
            termLength: offer.termLength
        });

        // Transfer token from creditor to debtor via the contract
        // First, transfer from creditor to this contract
        bool transferFromSuccess = IERC20(offer.token).transferFrom(offer.creditor, address(this), offer.loanAmount);
        if (!transferFromSuccess) revert TransferFailed();
        
        // Then transfer from this contract to debtor
        bool transferSuccess = IERC20(offer.token).transfer(offer.debtor, offer.loanAmount);
        if (!transferSuccess) revert TransferFailed();
        emit LoanOfferAccepted(offerId, claimId, block.timestamp);

        return claimId;
    }

    /**
     * @notice Pays a loan
     * @param claimId The ID of the loan to pay
     * @param amount The amount to pay
     */
    function payLoan(uint256 claimId, uint256 amount) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);
        address creditor = _bullaClaim.ownerOf(claimId);

        (uint256 remainingPrincipal, uint256 currentInterest) = getTotalAmountDue(claimId);
        
        uint256 interestPayment = Math.min(amount, currentInterest);
        uint256 principalPayment = amount - interestPayment;
        
        principalPayment = Math.min(principalPayment, remainingPrincipal);
        
        // Send interest payment directly from debtor to creditor
        if (interestPayment > 0) {
            bool interestTransferSuccess = IERC20(claim.token).transferFrom(msg.sender, creditor, interestPayment);
            if (!interestTransferSuccess) revert TransferFailed();
        }
        
        // Process principal payment through BullaClaim
        if (principalPayment > 0) {
            _bullaClaim.payClaimFrom(msg.sender, claimId, principalPayment);
        }
        
        emit LoanPayment(claimId, interestPayment, principalPayment, block.timestamp);
    }

    /**
     * @notice Allows an admin to withdraw fees from the contract
     * @param amount The amount to withdraw
     */
    function withdrawFee(uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();

        (bool success, ) = admin.call{value: amount}("");
        if (!success) revert WithdrawalFailed();
    }
}