// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./interfaces/IBullaClaimV2.sol";
import "./interfaces/IBullaFrendLendV2.sol";
import "./BullaClaimControllerBase.sol";
import "./types/Types.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {InterestConfig, InterestComputationState, CompoundInterestLib} from "./libraries/CompoundInterestLib.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
error LoanOfferExpired();
error CallbackFailed(bytes data);

error CallbackNotWhitelisted();
error TokenNotWhitelistedForFeeWithdrawal();

/**
 * @title BullaFrendLendV2
 * @notice A wrapper contract for IBullaClaim that allows both creditors to offer loans that debtors can accept,
 *         and debtors to request loans that creditors can accept
 */
contract BullaFrendLendV2 is BullaClaimControllerBase, ERC165, Ownable, IBullaFrendLendV2 {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;

    uint256 public loanOfferCount;
    uint16 public protocolFeeBPS;
    uint16 public processingFeeBPS;

    address[] public whitelistedProtocolFeeTokens;
    mapping(address => uint256) public protocolFeesByToken;

    // Whitelist for protocol fee token withdrawals
    mapping(address => bool) public protocolFeeTokenWhitelist;

    // Whitelist for callback contracts and selectors
    mapping(address => mapping(bytes4 => bool)) public callbackWhitelist;

    mapping(uint256 => LoanOffer) private _loanOffers;
    mapping(uint256 => LoanDetails) private _loanDetailsByClaimId;
    mapping(uint256 => ClaimMetadata) private _loanOfferMetadata;

    ClaimMetadata private _emptyMetadata;

    /**
     * @param bullaClaim Address of the IBullaClaim contract to delegate calls to
     * @param _owner Address of the contract owner
     * @param _protocolFeeBPS Protocol fee in basis points taken from interest payments
     * @param _processingFeeBPS Processing fee in basis points taken from loan amount on acceptance
     */
    constructor(address bullaClaim, address _owner, uint16 _protocolFeeBPS, uint16 _processingFeeBPS)
        BullaClaimControllerBase(bullaClaim)
        Ownable(_owner)
    {
        if (_protocolFeeBPS > MAX_BPS) revert InvalidProtocolFee();
        if (_processingFeeBPS > MAX_BPS) revert InvalidProtocolFee();
        protocolFeeBPS = _protocolFeeBPS;
        processingFeeBPS = _processingFeeBPS;
        _emptyMetadata = ClaimMetadata({tokenURI: "", attachmentURI: ""});
    }

    ////////////////////////////////
    // View functions
    ////////////////////////////////

    /**
     * @notice Get the total amount due for a loan including principal and interest. This function will compute the interest if the loan is not paid.
     * @param claimId The ID of the loan
     * @return remainingPrincipal The remaining principal amount due
     * @return grossInterest The current gross interest amount accrued
     */
    function getTotalAmountDue(uint256 claimId)
        public
        view
        returns (uint256 remainingPrincipal, uint256 grossInterest)
    {
        Loan memory loan = getLoan(claimId);

        return getTotalAmountDue(loan);
    }

    /**
     * @notice Get the total amount due for a loan including principal and interest. This function will compute the interest if the loan is not paid.
     * @param loan The loan to get the total amount due for
     * @return remainingPrincipal The remaining principal amount due
     * @return grossInterest The current gross interest amount accrued
     */
    function getTotalAmountDue(Loan memory loan)
        private
        pure
        returns (uint256 remainingPrincipal, uint256 grossInterest)
    {
        remainingPrincipal = loan.claimAmount - loan.paidAmount;
        grossInterest = loan.interestComputationState.accruedInterest;
    }

    /**
     * @notice Get a loan with all its details. This function will compute the interest if the loan is not paid.
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
            debtor: claim.debtor,
            creditor: claim.creditor,
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
        if (offerId >= loanOfferCount) revert LoanOfferNotFound();
        return _loanOffers[offerId];
    }

    /**
     * @notice Get loan offer metadata by ID
     * @param offerId The ID of the loan offer
     * @return The metadata for the loan offer
     */
    function getLoanOfferMetadata(uint256 offerId) public view returns (ClaimMetadata memory) {
        if (offerId >= loanOfferCount) revert LoanOfferNotFound();
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
    function offerLoan(LoanRequestParams calldata offer) external returns (uint256) {
        return _offerLoan(offer, _emptyMetadata);
    }

    function _offerLoan(LoanRequestParams calldata offer, ClaimMetadata memory metadata) private returns (uint256) {
        bool requestedByCreditor = msg.sender == offer.creditor;

        _validateLoanOffer(offer, requestedByCreditor);

        uint256 offerId = loanOfferCount++;
        _loanOffers[offerId] = LoanOffer({params: offer, requestedByCreditor: requestedByCreditor});

        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            _loanOfferMetadata[offerId] = metadata;
        }

        emit LoanOffered(offerId, msg.sender, offer, metadata);

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
    function acceptLoan(uint256 offerId) external payable returns (uint256) {
        return _acceptLoan(msg.sender, offerId, address(0));
    }

    /**
     * @notice Allows a debtor to accept a loan offer with a custom receiver address
     * @dev Only works when debtor is accepting a creditor's offer
     * @param offerId The ID of the loan offer to accept
     * @param receiver The address that should receive the loan funds
     * @return The ID of the created claim
     */
    function acceptLoanWithReceiver(uint256 offerId, address receiver) external payable returns (uint256) {
        return _acceptLoan(msg.sender, offerId, receiver);
    }

    function _acceptLoan(address from, uint256 offerId, address receiver) private returns (uint256) {
        LoanOffer memory offer = _loanOffers[offerId];

        if (offer.params.creditor == address(0)) revert LoanOfferNotFound();

        // Check exemption based on the debtor (the person getting indebted)
        bool isProtocolFeeExempt = _bullaClaim.feeExemptions().isAllowed(offer.params.debtor)
            || _bullaClaim.feeExemptions().isAllowed(offer.params.creditor);

        uint256 fee = isProtocolFeeExempt ? 0 : _bullaClaim.CORE_PROTOCOL_FEE();

        if (msg.value != fee) revert IncorrectFee();

        // Check if offer has expired (only if expiresAt is set to a non-zero value)
        if (offer.params.expiresAt > 0 && block.timestamp > offer.params.expiresAt) {
            revert LoanOfferExpired();
        }

        // Check if the correct person is accepting the loan
        if (offer.requestedByCreditor) {
            // Creditor made offer, debtor should accept
            if (from != offer.params.debtor) revert NotDebtor();
        } else {
            // Debtor made request, creditor should accept
            if (from != offer.params.creditor) revert NotCreditor();
            // Receiver override is only allowed when debtor accepts creditor's offer
            if (receiver != address(0)) revert NotDebtor();
        }

        // Determine the final receiver address
        address finalReceiver = receiver != address(0) ? receiver : offer.params.debtor;

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
            dueBy: block.timestamp + offer.params.termLength,
            impairmentGracePeriod: offer.params.impairmentGracePeriod
        });

        // Create the claim via BullaClaim - always use the debtor as the originator
        uint256 claimId;
        if (bytes(metadata.tokenURI).length > 0 || bytes(metadata.attachmentURI).length > 0) {
            claimId = _bullaClaim.createClaimWithMetadataFrom{value: fee}(offer.params.debtor, claimParams, metadata);
        } else {
            claimId = _bullaClaim.createClaimFrom{value: fee}(offer.params.debtor, claimParams);
        }

        _loanDetailsByClaimId[claimId] = LoanDetails({
            acceptedAt: block.timestamp,
            interestConfig: offer.params.interestConfig,
            interestComputationState: InterestComputationState({
                accruedInterest: 0,
                latestPeriodNumber: 0,
                protocolFeeBps: isProtocolFeeExempt ? 0 : protocolFeeBPS,
                totalGrossInterestPaid: 0
            }),
            isProtocolFeeExempt: isProtocolFeeExempt
        });

        // Calculate processing fee from loan amount (taken on acceptance)
        // Note: Processing fee is independent of protocol fee exemptions
        uint256 processingFee = Math.mulDiv(offer.params.loanAmount, processingFeeBPS, MAX_BPS);
        uint256 amountToReceiver = offer.params.loanAmount - processingFee;

        // Track processing fee if any
        if (processingFee > 0) {
            protocolFeesByToken[offer.params.token] += processingFee;
        }

        // Transfer full loan amount from creditor to this contract
        ERC20(offer.params.token).safeTransferFrom(offer.params.creditor, address(this), offer.params.loanAmount);

        // Transfer loan amount minus processing fee to receiver
        if (amountToReceiver > 0) {
            ERC20(offer.params.token).safeTransfer(finalReceiver, amountToReceiver);
        }

        // Execute callback if configured
        if (offer.params.callbackContract != address(0)) {
            _executeCallback(offer.params.callbackContract, offer.params.callbackSelector, offerId, claimId);
        }

        emit LoanOfferAccepted(offerId, claimId, finalReceiver, fee, processingFee, metadata);

        return claimId;
    }

    /**
     * @notice Pays a loan
     * @param claimId The ID of the loan to pay
     * @param paymentAmount The amount to pay
     */
    function payLoan(uint256 claimId, uint256 paymentAmount) external {
        Loan memory loan = getLoan(claimId);

        (uint256 remainingPrincipal, uint256 grossInterest) = getTotalAmountDue(loan);

        uint256 grossInterestBeingPaid = Math.min(paymentAmount, grossInterest);
        uint256 principalPayment = Math.min(paymentAmount - grossInterestBeingPaid, remainingPrincipal);

        _loanDetailsByClaimId[claimId].interestComputationState = InterestComputationState({
            accruedInterest: loan.interestComputationState.accruedInterest - grossInterestBeingPaid,
            latestPeriodNumber: loan.interestComputationState.latestPeriodNumber,
            protocolFeeBps: loan.interestComputationState.protocolFeeBps,
            totalGrossInterestPaid: loan.interestComputationState.totalGrossInterestPaid + grossInterestBeingPaid
        });

        // Calculate total actual payment (interest + principal)
        paymentAmount = grossInterestBeingPaid + principalPayment;

        uint256 protocolFee = _loanDetailsByClaimId[claimId].isProtocolFeeExempt || grossInterestBeingPaid == 0
            ? 0
            : _calculateProtocolFee(
                grossInterestBeingPaid, loan.interestConfig.interestRateBps, loan.interestComputationState.protocolFeeBps
            );

        uint256 creditorInterest = grossInterestBeingPaid - protocolFee;
        uint256 creditorTotal = creditorInterest + principalPayment;

        // Update claim state in BullaClaim BEFORE transfers (for re-entrancy protection)
        if (principalPayment > 0) {
            _bullaClaim.payClaimFromControllerWithoutTransfer(msg.sender, claimId, principalPayment);
        }

        // Transfer the total amount from sender to this contract, to avoid double approval
        if (paymentAmount > 0) {
            // Track protocol fee for this token if any interest was paid, even if token is not whitelisted
            if (protocolFee > 0) {
                protocolFeesByToken[loan.token] += protocolFee;
            }

            ERC20(loan.token).safeTransferFrom(msg.sender, address(this), paymentAmount);

            if (creditorTotal > 0) {
                // Transfer interest and principal to creditor
                ERC20(loan.token).safeTransfer(loan.creditor, creditorTotal);
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
     * @notice Allows owner to withdraw accumulated protocol fees
     */
    function withdrawAllFees() external onlyOwner {
        // Withdraw protocol fees in all whitelisted tokens
        for (uint256 i = 0; i < whitelistedProtocolFeeTokens.length; i++) {
            address token = whitelistedProtocolFeeTokens[i];
            uint256 feeAmount = protocolFeesByToken[token];

            if (feeAmount > 0) {
                protocolFeesByToken[token] = 0; // Reset fee amount before transfer
                ERC20(token).safeTransfer(owner(), feeAmount);
                emit FeeWithdrawn(owner(), token, feeAmount);
            }
        }
    }

    /**
     * @notice Allows owner to set the protocol fee percentage
     * @param _protocolFeeBPS New protocol fee in basis points
     */
    function setProtocolFee(uint16 _protocolFeeBPS) external onlyOwner {
        if (_protocolFeeBPS > MAX_BPS) revert InvalidProtocolFee();

        uint16 oldFee = protocolFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;

        emit ProtocolFeeUpdated(oldFee, _protocolFeeBPS);
    }

    /**
     * @notice Allows owner to set the processing fee percentage
     * @param _processingFeeBPS New processing fee in basis points
     */
    function setProcessingFee(uint16 _processingFeeBPS) external onlyOwner {
        if (_processingFeeBPS > MAX_BPS) revert InvalidProtocolFee();

        uint16 oldFee = processingFeeBPS;
        processingFeeBPS = _processingFeeBPS;

        emit ProcessingFeeUpdated(oldFee, _processingFeeBPS);
    }

    /**
     * @notice Allows owner to add a token to the withdrawal whitelist
     * @param token The token address to whitelist for withdrawals
     */
    function addToFeeTokenWhitelist(address token) external onlyOwner {
        if (!protocolFeeTokenWhitelist[token]) {
            protocolFeeTokenWhitelist[token] = true;
            whitelistedProtocolFeeTokens.push(token);
        }

        emit TokenAddedToFeesWhitelist(token);
    }

    /**
     * @notice Allows owner to remove a token from the withdrawal whitelist
     * @param token The token address to remove from withdrawal whitelist
     */
    function removeFromFeeTokenWhitelist(address token) external onlyOwner {
        if (protocolFeeTokenWhitelist[token]) {
            protocolFeeTokenWhitelist[token] = false;

            // Remove from whitelistedProtocolFeeTokens array
            for (uint256 i = 0; i < whitelistedProtocolFeeTokens.length; i++) {
                if (whitelistedProtocolFeeTokens[i] == token) {
                    whitelistedProtocolFeeTokens[i] =
                        whitelistedProtocolFeeTokens[whitelistedProtocolFeeTokens.length - 1];
                    whitelistedProtocolFeeTokens.pop();
                    break;
                }
            }
        }

        emit TokenRemovedFromFeesWhitelist(token);
    }

    /**
     * @notice Allows owner to add a callback contract and selector to the whitelist
     * @param callbackContract The contract address to whitelist
     * @param selector The function selector to whitelist for this contract
     */
    function addToCallbackWhitelist(address callbackContract, bytes4 selector) external onlyOwner {
        // Don't allow whitelisting zero address or zero selector
        if (callbackContract == address(0) || selector == bytes4(0)) {
            return;
        }

        callbackWhitelist[callbackContract][selector] = true;

        emit CallbackWhitelisted(callbackContract, selector);
    }

    /**
     * @notice Allows owner to remove a callback contract and selector from the whitelist
     * @param callbackContract The contract address to remove from whitelist
     * @param selector The function selector to remove from whitelist for this contract
     */
    function removeFromCallbackWhitelist(address callbackContract, bytes4 selector) external onlyOwner {
        callbackWhitelist[callbackContract][selector] = false;

        emit CallbackRemovedFromWhitelist(callbackContract, selector);
    }

    /**
     * @notice Returns the admin address (owner) for interface compatibility
     * @return The address of the owner
     */
    function admin() external view returns (address) {
        return owner();
    }

    /**
     * @notice Check if a callback contract and selector combination is whitelisted
     * @param callbackContract The contract address to check
     * @param selector The function selector to check
     * @return True if the combination is whitelisted, false otherwise
     */
    function isCallbackWhitelisted(address callbackContract, bytes4 selector) external view returns (bool) {
        return callbackWhitelist[callbackContract][selector];
    }

    ////////////////////////////////
    // Private functions
    ////////////////////////////////

    function _validateLoanOffer(LoanRequestParams calldata offer, bool requestedByCreditor) private view {
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

        // Check callback whitelist if callback is configured
        if (offer.callbackContract != address(0)) {
            if (!callbackWhitelist[offer.callbackContract][offer.callbackSelector]) {
                revert CallbackNotWhitelisted();
            }
        }

        CompoundInterestLib.validateInterestConfig(offer.interestConfig);
    }

    /**
     * @notice Calculate the protocol fee amount based on interest payment
     * @param grossInterestAmount The interest amount to calculate fee from
     * @return The protocol fee amount
     */
    function _calculateProtocolFee(uint256 grossInterestAmount, uint16 interestRateBps, uint16 protocolFeeBps)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(grossInterestAmount, uint256(protocolFeeBps), uint256(interestRateBps + protocolFeeBps));
    }

    /**
     * @notice Execute callback to the specified contract after loan acceptance
     * @param callbackContract The contract to call
     * @param callbackSelector The function selector to call
     * @param loanOfferId The ID of the accepted loan offer
     * @param claimId The ID of the created claim
     */
    function _executeCallback(address callbackContract, bytes4 callbackSelector, uint256 loanOfferId, uint256 claimId)
        private
    {
        bytes memory callData = abi.encodeWithSelector(callbackSelector, loanOfferId, claimId);

        (bool success, bytes memory returnData) = callbackContract.call(callData);
        if (!success) {
            revert CallbackFailed(returnData);
        }
    }

    /**
     * @notice Returns true if this contract implements the interface defined by interfaceId
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return True if the contract implements interfaceId
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IBullaFrendLendV2).interfaceId || _supportsERC721Interface(interfaceId)
            || super.supportsInterface(interfaceId);
    }
}
