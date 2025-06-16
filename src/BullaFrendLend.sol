// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/interfaces/IBullaFrendLend.sol";
import "contracts/BullaClaimControllerBase.sol";
import "contracts/types/Types.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {
    InterestConfig, InterestComputationState, CompoundInterestLib
} from "contracts/libraries/CompoundInterestLib.sol";
import {BoringBatchable} from "contracts/libraries/BoringBatchable.sol";

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
error InvalidProtocolFee();
error InvalidGracePeriod();
error FrendLendBatchInvalidMsgValue();
error FrendLendBatchInvalidCalldata();
error LoanOfferExpired();

/**
 * @title BullaFrendLend
 * @notice A wrapper contract for IBullaClaim that allows both creditors to offer loans that debtors can accept,
 *         and debtors to request loans that creditors can accept
 */
contract BullaFrendLend is BullaClaimControllerBase, BoringBatchable, ERC165, IBullaFrendLend {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;

    address public admin;
    uint256 public fee;
    uint256 public loanOfferCount;
    uint256 public protocolFeeBPS;

    address[] public protocolFeeTokens;
    mapping(address => uint256) public protocolFeesByToken;
    mapping(address => bool) private _tokenExists;

    mapping(uint256 => LoanOffer) private _loanOffers;
    mapping(uint256 => LoanDetails) private _loanDetailsByClaimId;
    mapping(uint256 => ClaimMetadata) private _loanOfferMetadata;

    // Track if we're currently in a batch operation to skip individual fee validation
    bool private _inBatchOperation;

    event LoanOffered(
        uint256 indexed loanId, address indexed offeredBy, LoanRequestParams loanOffer, uint256 originationFee
    );
    event LoanOfferAccepted(uint256 indexed loanId, uint256 indexed claimId);
    event LoanOfferRejected(uint256 indexed loanId, address indexed rejectedBy);
    /// @notice grossInterestPaid = interest received by creditor + protocolFee
    event LoanPayment(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);

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

    ////////////////////////////////
    // View functions
    ////////////////////////////////

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
     * @notice Get a loan offer by ID
     * @param offerId The ID of the loan offer
     * @return The loan offer details
     */
    function getLoanOffer(uint256 offerId) public view returns (LoanOffer memory) {
        return _loanOffers[offerId];
    }

    /**
     * @notice Get loan offer metadata by ID
     * @param offerId The ID of the loan offer
     * @return The metadata for the loan offer
     */
    function getLoanOfferMetadata(uint256 offerId) public view returns (ClaimMetadata memory) {
        return _loanOfferMetadata[offerId];
    }

    ////////////////////////////////
    // Offer functions
    ////////////////////////////////

    /**
     * @notice Allows a user to create and offer a loan with metadata
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
     * @notice Allows a user to create and offer a loan
     * @dev If caller is creditor, creates an offer for debtor to accept
     * @dev If caller is debtor, creates a request for creditor to accept
     * @param offer The loan offer parameters
     * @return The ID of the created loan offer
     */
    function offerLoan(LoanRequestParams calldata offer) external payable returns (uint256) {
        return _offerLoan(offer, _emptyMetadata);
    }

    function _offerLoan(LoanRequestParams calldata offer, ClaimMetadata memory metadata) private returns (uint256) {
        bool requestedByCreditor = msg.sender == offer.creditor;

        _validateLoanOffer(offer, requestedByCreditor);

        uint256 offerId = ++loanOfferCount;
        _loanOffers[offerId] = LoanOffer({params: offer, requestedByCreditor: requestedByCreditor});

        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            _loanOfferMetadata[offerId] = metadata;
        }

        emit LoanOffered(offerId, msg.sender, offer, msg.value);

        return offerId;
    }

    ////////////////////////////////
    // Other core functions
    ////////////////////////////////

    /**
     * @notice Allows a debtor or creditor to reject or rescind a loan offer
     * @param offerId The ID of the loan offer to reject
     */
    function rejectLoanOffer(uint256 offerId) external {
        LoanOffer memory offer = _loanOffers[offerId];

        if (offer.params.creditor == address(0)) revert LoanOfferNotFound();
        if (msg.sender != offer.params.creditor && msg.sender != offer.params.debtor) revert NotCreditorOrDebtor();

        delete _loanOffers[offerId];
        delete _loanOfferMetadata[offerId];

        emit LoanOfferRejected(offerId, msg.sender);
    }

    /**
     * @notice Allows the counterparty to accept a loan offer
     * @dev If offer was made by creditor, debtor can accept to receive funds
     * @dev If offer was made by debtor, creditor can accept to provide funds
     * @param offerId The ID of the loan offer to accept
     * @return The ID of the created claim
     */
    function acceptLoan(uint256 offerId) external returns (uint256) {
        LoanOffer memory offer = _loanOffers[offerId];

        if (offer.params.creditor == address(0)) revert LoanOfferNotFound();

        // Check if offer has expired (only if expiresAt is set to a non-zero value)
        if (offer.params.expiresAt > 0 && block.timestamp > offer.params.expiresAt) {
            revert LoanOfferExpired();
        }

        // Check if the correct person is accepting the loan
        if (offer.requestedByCreditor) {
            // Creditor made offer, debtor should accept
            if (msg.sender != offer.params.debtor) revert NotDebtor();
        } else {
            // Debtor made request, creditor should accept
            if (msg.sender != offer.params.creditor) revert NotCreditor();
        }

        ClaimMetadata memory metadata = _loanOfferMetadata[offerId];

        // Clean up storage
        delete _loanOffers[offerId];
        delete _loanOfferMetadata[offerId];

        CreateClaimParams memory claimParams = CreateClaimParams({
            creditor: offer.params.creditor,
            debtor: offer.params.debtor,
            claimAmount: offer.params.loanAmount,
            description: offer.params.description,
            token: offer.params.token,
            binding: ClaimBinding.Bound, // Loans are bound claims, avoiding the 1 wei transfer used in V1
            payerReceivesClaimOnPayment: true,
            dueBy: block.timestamp + offer.params.termLength,
            impairmentGracePeriod: offer.params.impairmentGracePeriod
        });

        // Create the claim via BullaClaim - always use the debtor as the originator
        uint256 claimId;
        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            claimId = _bullaClaim.createClaimWithMetadataFrom(offer.params.debtor, claimParams, metadata);
        } else {
            claimId = _bullaClaim.createClaimFrom(offer.params.debtor, claimParams);
        }

        _loanDetailsByClaimId[claimId] = LoanDetails({
            acceptedAt: block.timestamp,
            interestConfig: offer.params.interestConfig,
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0})
        });

        // Transfer token from creditor to debtor via the contract
        // First, transfer from creditor to this contract
        ERC20(offer.params.token).safeTransferFrom(offer.params.creditor, address(this), offer.params.loanAmount);

        // Then transfer from this contract to debtor
        ERC20(offer.params.token).safeTransfer(offer.params.debtor, offer.params.loanAmount);

        emit LoanOfferAccepted(offerId, claimId);

        return claimId;
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

        uint256 grossInterestBeingPaid = Math.min(paymentAmount, interest);
        uint256 principalPayment = Math.min(paymentAmount - grossInterestBeingPaid, remainingPrincipal);

        // Calculate total actual payment (interest + principal)
        paymentAmount = grossInterestBeingPaid + principalPayment;

        uint256 protocolFee = _calculateProtocolFee(grossInterestBeingPaid);
        uint256 creditorInterest = grossInterestBeingPaid - protocolFee;
        uint256 creditorTotal = creditorInterest + principalPayment;

        // Update claim state in BullaClaim BEFORE transfers (for re-entrancy protection)
        if (principalPayment > 0) {
            _bullaClaim.payClaimFromControllerWithoutTransfer(msg.sender, claimId, principalPayment);
        }

        // Transfer the total amount from sender to this contract, to avoid double approval
        if (paymentAmount > 0) {
            // Track protocol fee for this token if any interest was paid
            if (protocolFee > 0) {
                if (!_tokenExists[claim.token]) {
                    protocolFeeTokens.push(claim.token);
                    _tokenExists[claim.token] = true;
                }
                protocolFeesByToken[claim.token] += protocolFee;
            }

            ERC20(claim.token).safeTransferFrom(msg.sender, address(this), paymentAmount);

            if (creditorTotal > 0) {
                // Transfer interest and principal to creditor
                ERC20(claim.token).safeTransfer(creditor, creditorTotal);
            }
        }

        emit LoanPayment(claimId, grossInterestBeingPaid, principalPayment, protocolFee);
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

    ////////////////////////////////
    // Admin functions
    ////////////////////////////////

    /**
     * @notice Allows admin to withdraw accumulated protocol fees and loanOffer fees
     */
    function withdrawAllFees() external {
        if (msg.sender != admin) revert NotAdmin();

        uint256 ethBalance = address(this).balance;
        // Withdraw fees related to loan offers in native token
        if (ethBalance > 0) {
            admin.safeTransferETH(ethBalance);
            emit FeeWithdrawn(admin, address(0), ethBalance);
        }

        // Withdraw protocol fees in all tracked tokens
        for (uint256 i = 0; i < protocolFeeTokens.length; i++) {
            address token = protocolFeeTokens[i];
            uint256 feeAmount = protocolFeesByToken[token];

            if (feeAmount > 0) {
                protocolFeesByToken[token] = 0; // Reset fee amount before transfer
                ERC20(token).safeTransfer(admin, feeAmount);
                emit FeeWithdrawn(admin, token, feeAmount);
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

    /**
     * @notice Batch create multiple loan offers with proper msg.value handling
     * @param calls Array of encoded offerLoan or offerLoanWithMetadata calls
     */
    function batchOfferLoans(bytes[] calldata calls) external payable {
        if (calls.length == 0) return;

        uint256 totalRequiredFee = 0;

        // Calculate total required fees by decoding each call
        for (uint256 i = 0; i < calls.length; i++) {
            bytes4 selector = bytes4(calls[i][:4]);

            if (selector == this.offerLoan.selector || selector == this.offerLoanWithMetadata.selector) {
                totalRequiredFee += fee;
            } else {
                revert FrendLendBatchInvalidCalldata();
            }
        }

        // Validate total msg.value matches required fees
        if (msg.value != totalRequiredFee) {
            revert FrendLendBatchInvalidMsgValue();
        }

        // Set batch operation flag before executing calls
        _inBatchOperation = true;

        // Execute each call
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) {
                _inBatchOperation = false; // Reset flag before reverting
                revert(_getRevertMsg(result));
            }
        }

        // Reset batch operation flag after successful execution
        _inBatchOperation = false;
    }

    ////////////////////////////////
    // Private functions
    ////////////////////////////////

    function _validateLoanOffer(LoanRequestParams calldata offer, bool requestedByCreditor) private view {
        // Skip fee validation when in batch operation (fees are validated at batch level)
        if (!_inBatchOperation) {
            if (msg.value != fee) revert IncorrectFee();
        }

        if (!requestedByCreditor && msg.sender != offer.debtor) {
            revert NotCreditorOrDebtor();
        }
        if (offer.termLength == 0) revert InvalidTermLength();
        if (offer.token == address(0)) revert NativeTokenNotSupported();
        if (offer.impairmentGracePeriod > type(uint40).max) revert InvalidGracePeriod();

        // Check if offer has expired (only if expiresAt is set to a non-zero value)
        if (offer.expiresAt > 0 && block.timestamp > offer.expiresAt) {
            revert LoanOfferExpired();
        }

        CompoundInterestLib.validateInterestConfig(offer.interestConfig);
    }

    /**
     * @notice Calculate the protocol fee amount based on interest payment
     * @param grossInterestAmount The interest amount to calculate fee from
     * @return The protocol fee amount
     */
    function _calculateProtocolFee(uint256 grossInterestAmount) private view returns (uint256) {
        return Math.mulDiv(grossInterestAmount, protocolFeeBPS, MAX_BPS);
    }

    /**
     * @notice Returns true if this contract implements the interface defined by interfaceId
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return True if the contract implements interfaceId
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBullaFrendLend).interfaceId || super.supportsInterface(interfaceId);
    }
}
