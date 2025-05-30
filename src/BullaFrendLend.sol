// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/BullaClaimControllerBase.sol";
import "contracts/types/Types.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    InterestConfig, InterestComputationState, CompoundInterestLib
} from "contracts/libraries/CompoundInterestLib.sol";

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
error LoanRequestNotFound();
error NativeTokenNotSupported();
error InvalidProtocolFee();
error InvalidGracePeriod();

struct LoanDetails {
    uint256 acceptedAt;
    InterestConfig interestConfig;
    InterestComputationState interestComputationState;
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
}

struct LoanRequest {
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
 * @title BullaFrendLend
 * @notice A wrapper contract for IBullaClaim that allows both creditors to offer loans that debtors can accept,
 *         and debtors to request loans that creditors can accept
 */
contract BullaFrendLend is BullaClaimControllerBase {
    address public admin;
    uint256 public fee;
    uint256 public loanOfferCount;
    uint256 public loanRequestCount;
    uint256 public protocolFeeBPS;

    address[] public protocolFeeTokens;
    mapping(address => uint256) public protocolFeesByToken;
    mapping(address => bool) private _tokenExists;

    mapping(uint256 => LoanRequest) public loanRequests;
    mapping(uint256 => LoanDetails) private _loanDetailsByClaimId;
    mapping(uint256 => ClaimMetadata) public loanRequestMetadata;

    event LoanOffered(uint256 indexed loanId, address indexed offeredBy, LoanRequestParams loanOffer);
    event LoanOfferAccepted(uint256 indexed loanId, uint256 indexed claimId);
    event LoanOfferRejected(uint256 indexed loanId, address indexed rejectedBy);
    event LoanRequested(uint256 indexed requestId, address indexed requestedBy, LoanRequestParams loanRequest);
    event LoanRequestAccepted(uint256 indexed requestId, uint256 indexed claimId);
    event LoanRequestRejected(uint256 indexed requestId, address indexed rejectedBy);
    event LoanPayment(uint256 indexed claimId, uint256 interestPayment, uint256 principalPayment, uint256 protocolFee);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);

    ClaimMetadata private _emptyMetadata;

    /**
     * @param bullaClaim Address of the IBullaClaim contract to delegate calls to
     * @param _admin Address of the contract administrator
     * @param _fee Fee required to create a loan offer
     * @param _protocolFeeBPS Protocol fee in basis points taken from interest payments
     */
    constructor(address bullaClaim, address _admin, uint256 _fee, uint256 _protocolFeeBPS)
        BullaClaimControllerBase(bullaClaim)
    {
        admin = _admin;
        fee = _fee;
        if (_protocolFeeBPS > MAX_BPS) revert InvalidProtocolFee();
        protocolFeeBPS = _protocolFeeBPS;
        _emptyMetadata = ClaimMetadata({tokenURI: "", attachmentURI: ""});
    }

    /**
     * @notice Get the total amount due for a loan including principal and interest
     * @param claimId The ID of the loan
     * @return remainingPrincipal The remaining principal amount due
     * @return interest The current interest amount accrued
     */
    function getTotalAmountDue(uint256 claimId) public view returns (uint256 remainingPrincipal, uint256 interest) {
        Loan memory loan = getLoan(claimId);

        remainingPrincipal = loan.claimAmount - loan.paidAmount;
        interest = loan.interestComputationState.accruedInterest;
    }

    /**
     * @notice Get a loan with all its details
     * @param claimId The ID of the claim associated with the loan
     * @return The loan details
     */
    function getLoan(uint256 claimId) public view returns (Loan memory) {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        LoanDetails memory loanDetails = _loanDetailsByClaimId[claimId];

        if (claim.status == Status.Pending || claim.status == Status.Repaying || claim.status == Status.Impaired) {
            loanDetails.interestComputationState = CompoundInterestLib.computeInterest(
                claim.claimAmount - claim.paidAmount,
                loanDetails.acceptedAt,
                loanDetails.interestConfig,
                loanDetails.interestComputationState
            );
        }

        return Loan({
            claimAmount: claim.claimAmount,
            paidAmount: claim.paidAmount,
            status: claim.status,
            binding: claim.binding,
            payerReceivesClaimOnPayment: claim.payerReceivesClaimOnPayment,
            debtor: claim.debtor,
            token: claim.token,
            controller: claim.controller,
            dueBy: claim.dueBy,
            acceptedAt: loanDetails.acceptedAt,
            interestConfig: loanDetails.interestConfig,
            interestComputationState: loanDetails.interestComputationState
        });
    }

    /**
     * @notice Allows a user to create and offer a loan to a potential debtor with metadata
     * @param offer The loan offer parameters
     * @param metadata Metadata for the claim (will be used when the loan is accepted)
     * @return The ID of the created loan offer
     */
    function offerLoanWithMetadata(LoanRequestParams calldata offer, ClaimMetadata calldata metadata)
        external
        payable
        returns (uint256)
    {
        return _offerLoan(offer, metadata);
    }

    /**
     * @notice Allows a user to create and offer a loan to a potential debtor
     * @param offer The loan offer parameters
     * @return The ID of the created loan offer
     */
    function offerLoan(LoanRequestParams calldata offer) external payable returns (uint256) {
        return _offerLoan(offer, _emptyMetadata);
    }

    function _offerLoan(LoanRequestParams calldata offer, ClaimMetadata memory metadata) private returns (uint256) {
        _validateLoanOffer(offer);

        uint256 offerId = ++loanOfferCount;
        loanRequests[offerId] = LoanRequest({
            params: offer,
            requestedByCreditor: true
        });

        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            loanRequestMetadata[offerId] = metadata;
        }

        emit LoanOffered(offerId, msg.sender, offer);

        return offerId;
    }

    /**
     * @notice Allows a debtor or creditor to reject or rescind a loan offer
     * @param offerId The ID of the loan offer to reject
     */
    function rejectLoanOffer(uint256 offerId) external {
        LoanRequest memory request = loanRequests[offerId];

        if (request.params.creditor == address(0)) revert LoanOfferNotFound();
        if (msg.sender != request.params.creditor && msg.sender != request.params.debtor) revert NotCreditorOrDebtor();

        delete loanRequests[offerId];
        delete loanRequestMetadata[offerId];

        emit LoanOfferRejected(offerId, msg.sender);
    }

    /**
     * @notice Allows a debtor to accept a loan offer and receive payment
     * @param offerId The ID of the loan offer to accept
     * @return The ID of the created claim
     */
    function acceptLoan(uint256 offerId) external returns (uint256) {
        LoanRequest memory request = loanRequests[offerId];

        if (request.params.creditor == address(0)) revert LoanOfferNotFound();
        if (msg.sender != request.params.debtor) revert NotDebtor();

        ClaimMetadata memory metadata = loanRequestMetadata[offerId];

        // Clean up storage
        delete loanRequests[offerId];
        delete loanRequestMetadata[offerId];

        CreateClaimParams memory claimParams = CreateClaimParams({
            creditor: request.params.creditor,
            debtor: request.params.debtor,
            claimAmount: request.params.loanAmount,
            description: request.params.description,
            token: request.params.token,
            binding: ClaimBinding.Bound, // Loans are bound claims, avoiding the 1 wei transfer used in V1
            payerReceivesClaimOnPayment: true,
            dueBy: block.timestamp + request.params.termLength,
            impairmentGracePeriod: request.params.impairmentGracePeriod
        });

        // Create the claim via BullaClaim
        uint256 claimId;
        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            claimId = _bullaClaim.createClaimWithMetadataFrom(msg.sender, claimParams, metadata);
        } else {
            claimId = _bullaClaim.createClaimFrom(msg.sender, claimParams);
        }

        _loanDetailsByClaimId[claimId] = LoanDetails({
            acceptedAt: block.timestamp,
            interestConfig: request.params.interestConfig,
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0})
        });

        // Transfer token from creditor to debtor via the contract
        // First, transfer from creditor to this contract
        bool transferFromSuccess = IERC20(request.params.token).transferFrom(request.params.creditor, address(this), request.params.loanAmount);
        if (!transferFromSuccess) revert TransferFailed();

        // Then transfer from this contract to debtor
        bool transferSuccess = IERC20(request.params.token).transfer(request.params.debtor, request.params.loanAmount);
        if (!transferSuccess) revert TransferFailed();
        emit LoanOfferAccepted(offerId, claimId);

        return claimId;
    }

    /**
     * @notice Allows a debtor to request a loan from a potential creditor with metadata
     * @param request The loan request parameters
     * @param metadata Metadata for the claim (will be used when the loan is accepted)
     * @return The ID of the created loan request
     */
    function requestLoanWithMetadata(LoanRequestParams calldata request, ClaimMetadata calldata metadata)
        external
        payable
        returns (uint256)
    {
        return _requestLoan(request, metadata);
    }

    /**
     * @notice Allows a debtor to request a loan from a potential creditor
     * @param request The loan request parameters
     * @return The ID of the created loan request
     */
    function requestLoan(LoanRequestParams calldata request) external payable returns (uint256) {
        return _requestLoan(request, _emptyMetadata);
    }

    function _requestLoan(LoanRequestParams calldata request, ClaimMetadata memory metadata) private returns (uint256) {
        _validateLoanRequest(request);

        uint256 requestId = ++loanRequestCount;
        loanRequests[requestId] = LoanRequest({
            params: request,
            requestedByCreditor: false
        });

        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            loanRequestMetadata[requestId] = metadata;
        }

        emit LoanRequested(requestId, msg.sender, request);

        return requestId;
    }

    /**
     * @notice Allows a debtor or creditor to reject or rescind a loan request
     * @param requestId The ID of the loan request to reject
     */
    function rejectLoanRequest(uint256 requestId) external {
        LoanRequest memory request = loanRequests[requestId];

        if (request.params.debtor == address(0)) revert LoanRequestNotFound();
        if (msg.sender != request.params.creditor && msg.sender != request.params.debtor) revert NotCreditorOrDebtor();

        delete loanRequests[requestId];
        delete loanRequestMetadata[requestId];

        emit LoanRequestRejected(requestId, msg.sender);
    }

    /**
     * @notice Allows a creditor to accept a loan request and provide funding
     * @param requestId The ID of the loan request to accept
     * @return The ID of the created claim
     */
    function acceptLoanRequest(uint256 requestId) external returns (uint256) {
        LoanRequest memory request = loanRequests[requestId];

        if (request.params.debtor == address(0)) revert LoanRequestNotFound();
        if (msg.sender != request.params.creditor) revert NotCreditor();

        ClaimMetadata memory metadata = loanRequestMetadata[requestId];

        // Clean up storage
        delete loanRequests[requestId];
        delete loanRequestMetadata[requestId];

        CreateClaimParams memory claimParams = CreateClaimParams({
            creditor: request.params.creditor,
            debtor: request.params.debtor,
            claimAmount: request.params.loanAmount,
            description: request.params.description,
            token: request.params.token,
            binding: ClaimBinding.Bound, // loans are bound claims
            payerReceivesClaimOnPayment: true,
            dueBy: block.timestamp + request.params.termLength,
            impairmentGracePeriod: request.params.impairmentGracePeriod
        });

        uint256 claimId;
        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            claimId = _bullaClaim.createClaimWithMetadataFrom(msg.sender, claimParams, metadata);
        } else {
            claimId = _bullaClaim.createClaimFrom(msg.sender, claimParams);
        }

        _loanDetailsByClaimId[claimId] = LoanDetails({
            acceptedAt: block.timestamp,
            interestConfig: request.params.interestConfig,
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0})
        });

        // Transfer token from creditor to debtor via the contract
        // First, transfer from creditor to this contract
        bool transferFromSuccess = IERC20(request.params.token).transferFrom(request.params.creditor, address(this), request.params.loanAmount);
        if (!transferFromSuccess) revert TransferFailed();

        // Then transfer from this contract to debtor
        bool transferSuccess = IERC20(request.params.token).transfer(request.params.debtor, request.params.loanAmount);
        if (!transferSuccess) revert TransferFailed();
        emit LoanRequestAccepted(requestId, claimId);

        return claimId;
    }

    /**
     * @notice Calculate the protocol fee amount based on interest payment
     * @param grossInterestAmount The interest amount to calculate fee from
     * @return The protocol fee amount
     */
    function calculateProtocolFee(uint256 grossInterestAmount) private view returns (uint256) {
        return Math.mulDiv(grossInterestAmount, protocolFeeBPS, MAX_BPS);
    }

    /**
     * @notice Pays a loan
     * @param claimId The ID of the loan to pay
     * @param paymentAmount The amount to pay
     */
    function payLoan(uint256 claimId, uint256 paymentAmount) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);
        address creditor = _bullaClaim.ownerOf(claimId);

        (uint256 remainingPrincipal, uint256 interest) = getTotalAmountDue(claimId);

        uint256 interestPayment = Math.min(paymentAmount, interest);
        uint256 principalPayment = Math.min(paymentAmount - interestPayment, remainingPrincipal);

        // Calculate total actual payment (interest + principal)
        paymentAmount = interestPayment + principalPayment;

        uint256 protocolFee = calculateProtocolFee(interestPayment);
        uint256 creditorInterest = interestPayment - protocolFee;
        uint256 creditorTotal = creditorInterest + principalPayment;

        // Update claim state in BullaClaim BEFORE transfers (for re-entrancy protection)
        if (principalPayment > 0) {
            _bullaClaim.payClaimFromControllerWithoutTransfer(msg.sender, claimId, principalPayment);
        }

        // Transfer the total amount from sender to this contract, to avoid double approval
        if (paymentAmount > 0) {
            bool transferSuccess = IERC20(claim.token).transferFrom(msg.sender, address(this), paymentAmount);
            if (!transferSuccess) revert TransferFailed();

            // Track protocol fee for this token if any interest was paid
            if (protocolFee > 0) {
                if (!_tokenExists[claim.token]) {
                    protocolFeeTokens.push(claim.token);
                    _tokenExists[claim.token] = true;
                }
                protocolFeesByToken[claim.token] += protocolFee;
            }

            if (creditorTotal > 0) {
                // Transfer interest and principal to creditor
                bool transferToCreditorSuccess = IERC20(claim.token).transfer(creditor, creditorTotal);
                if (!transferToCreditorSuccess) revert TransferFailed();
            }
        }

        emit LoanPayment(claimId, interestPayment, principalPayment, protocolFee);
    }

    /**
     * @notice Allows a creditor to impair a loan
     * @param claimId The ID of the loan to impair
     */
    function impairLoan(uint256 claimId) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.impairClaimFrom(msg.sender, claimId);
    }

    /**
     * @notice Allows a creditor to manually mark a loan as paid
     * @param claimId The ID of the loan to mark as paid
     */
    function markLoanAsPaid(uint256 claimId) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.markClaimAsPaidFrom(msg.sender, claimId);
    }

    /**
     * @notice Allows admin to withdraw accumulated protocol fees and loanOffer fees
     */
    function withdrawAllFees() external {
        if (msg.sender != admin) revert NotAdmin();

        // Withdraw fees related to loan offers in native token
        if (address(this).balance > 0) {
            (bool _success,) = admin.call{value: address(this).balance}("");
            if (!_success) revert WithdrawalFailed();
        }

        // Withdraw protocol fees in all tracked tokens
        for (uint256 i = 0; i < protocolFeeTokens.length; i++) {
            address token = protocolFeeTokens[i];
            uint256 feeAmount = protocolFeesByToken[token];

            if (feeAmount > 0) {
                protocolFeesByToken[token] = 0; // Reset fee amount before transfer
                bool success = IERC20(token).transfer(admin, feeAmount);
                if (!success) revert WithdrawalFailed();
            }
        }
    }

    /**
     * @notice Allows admin to set the protocol fee percentage
     * @param _protocolFeeBPS New protocol fee in basis points
     */
    function setProtocolFee(uint256 _protocolFeeBPS) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_protocolFeeBPS > MAX_BPS) revert InvalidProtocolFee();

        uint256 oldFee = protocolFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;

        emit ProtocolFeeUpdated(oldFee, _protocolFeeBPS);
    }

    function _validateLoanOffer(LoanRequestParams calldata offer) private view {
        if (msg.value != fee) revert IncorrectFee();
        if (msg.sender != offer.creditor) revert NotCreditor();
        if (offer.termLength == 0) revert InvalidTermLength();
        if (offer.token == address(0)) revert NativeTokenNotSupported();
        if (offer.impairmentGracePeriod > type(uint40).max) revert InvalidGracePeriod();

        CompoundInterestLib.validateInterestConfig(offer.interestConfig);
    }

    function _validateLoanRequest(LoanRequestParams calldata request) private view {
        if (msg.value != fee) revert IncorrectFee();
        if (msg.sender != request.debtor) revert NotDebtor();
        if (request.termLength == 0) revert InvalidTermLength();
        if (request.token == address(0)) revert NativeTokenNotSupported();
        if (request.impairmentGracePeriod > type(uint40).max) revert InvalidGracePeriod();

        CompoundInterestLib.validateInterestConfig(request.interestConfig);
    }
}
