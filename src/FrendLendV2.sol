// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {BullaClaim, CreateClaimParams, ClaimBinding, FeePayer, ClaimMetadata} from "contracts/BullaClaim.sol";

uint256 constant MAX_BPS = 10_000;

//TODO:
//1. loan offer is now deleted from storage, make sure that doesn't allow for double accepts

struct LoanOffer {
    bool accepted;
    FeePayer feePayer;
    bool payerReceivesClaimOnPayment;
    uint24 interestBPS; // can be 0
    uint40 termLength; // cannot be 0
    uint128 loanAmount;
    address creditor;
    address debtor;
    string description;
    address token;
    ClaimMetadata metadata;
}

/// @title FrendLend V2
/// @author @colinnielsen
/// @notice An extension to BullaClaim V2 that allows a creditor to offer capital in exchange for a claim
contract FrendLendV2 {
    using SafeTransferLib for ERC20;

    error NotController(address controller);

    /// address of the Bulla Claim contract
    BullaClaim public bullaClaim;
    /// the admin of the contract
    address public admin;
    /// the fee represented as the wei amount of the network's native token
    uint256 public fee;
    /// a mapping of id to the FinanceTerms offered by the creditor
    mapping(bytes32 => LoanOffer) public loanOffers;

    event LoanOffered(bytes32 indexed loanId, address indexed offeredBy, LoanOffer loanOffer, uint256 blocktime);
    event LoanOfferAccepted(bytes32 indexed loanId, uint256 indexed claimId, uint256 blocktime);
    event LoanOfferRejected(bytes32 indexed loanId, address indexed rejectedBy, uint256 blocktime);

    error INCORRECT_FEE();
    error NOT_CREDITOR();
    error NOT_DEBTOR();
    error NOT_CREDITOR_OR_DEBTOR();
    error NOT_ADMIN();
    error LOAN_CANNOT_BE_ACCEPTED();
    error INVALID_TERM_LENGTH();
    error WITHDRAWAL_FAILED();
    error TRANSFER_FAILED();

    constructor(BullaClaim _bullaClaim, address _admin, uint256 _fee) {
        bullaClaim = _bullaClaim;
        admin = _admin;
        fee = _fee;
    }

    ////// ADMIN FUNCTIONS //////

    /// @notice SPEC:
    ///     allows an admin to withdraw `withdrawableFee` amount of tokens from this contract's balance
    ///     Given the following: `msg.sender == admin`
    function withdrawFee(uint256 _amount) public {
        if (msg.sender != admin) revert NOT_ADMIN();

        (bool success,) = admin.call{value: _amount}("");
        if (!success) revert WITHDRAWAL_FAILED();
    }

    ////// USER FUNCTIONS //////

    /// @param offer claim creation params and loan info
    /// @notice SPEC:
    ///     Allows a user to create offer a loan to a potential debtor
    ///     This function will:
    ///         RES1. Store the offer parameters
    ///         RES2. Emit a LoanOffered event with the offer parameters, the offerId, the creator, and the current timestamp
    ///         RETURNS: the offerId
    ///     Given the following:
    ///         P1. `msg.value == fee`
    ///         P2. `msg.sender == offer.creditor`
    ///         P3. `terms.interestBPS < type(uint24).max`
    ///         P4. `terms.termLength < type(uint40).max`
    ///         P5. `terms.termLength > 0`
    ///         P6. `terms.accepted == false`
    function offerLoan(LoanOffer calldata offer) public payable returns (bytes32) {
        if (msg.value != fee) revert INCORRECT_FEE();
        if (msg.sender != offer.creditor) revert NOT_CREDITOR();
        if (offer.accepted) revert LOAN_CANNOT_BE_ACCEPTED();
        if (offer.termLength == 0) revert INVALID_TERM_LENGTH();

        bytes32 offerId = keccak256(abi.encode(msg.sender, offer.debtor, block.timestamp));
        loanOffers[offerId] = offer;

        emit LoanOffered(offerId, msg.sender, offer, block.timestamp);

        return offerId;
    }

    /// @param offerId the offerId to reject
    /// @notice SPEC:
    ///     Allows a debtor or a offerer to reject (or rescind) a loan offer
    ///     This function will:
    ///         RES1. Delete the offer from storage
    ///         RES2. Emit a LoanOfferRejected event with the offerId, the msg.sender, and the current timestamp
    ///     Given the following:
    ///         P1. the current msg.sender is either the creditor or debtor (covers: offer exists)
    function rejectLoanOffer(bytes32 offerId) public {
        LoanOffer memory offer = loanOffers[offerId];
        if (msg.sender != offer.creditor && msg.sender != offer.debtor) {
            revert NOT_CREDITOR_OR_DEBTOR();
        }

        delete loanOffers[offerId];

        emit LoanOfferRejected(offerId, msg.sender, block.timestamp);
    }

    /// @param offerId the offerId to accept
    /// @notice WARNING: is not designed to work with fee-on-transfer tokens
    /// @notice SPEC:
    ///     Allows a debtor to accept a loan offer, and receive payment
    ///     This function will:
    ///         RES1. Creates a new claim for the loan amount + interest
    ///         RES2. Transfers the offered loan amount from the creditor to the debtor
    ///         RES3. Puts the claim into a non-rejectable repaying state by paying 1 wei
    ///         RES4. Emits a BullaTagUpdated event with the claimId, the debtor address, a tag, and the current timestamp
    ///         RES5. Emits a LoanOfferAccepted event with the offerId, the accepted claimId, and the current timestamp
    ///     Given the following:
    ///         P1. the current msg.sender is the debtor listed on the offer (covers: offer exists)
    function acceptLoan(bytes32 offerId, uint256 initialPayment)
        // ,bytes32 tag
        public
    {
        LoanOffer memory offer = loanOffers[offerId];
        if (msg.sender != offer.debtor) revert NOT_DEBTOR();

        loanOffers[offerId].accepted == true;

        // delete unnecessary storage for gas refund
        delete loanOffers[offerId].creditor;
        delete loanOffers[offerId].debtor;
        delete loanOffers[offerId].description;
        delete loanOffers[offerId].token;
        delete loanOffers[offerId].metadata;

        uint256 claimId = bullaClaim.createClaimWithMetadataFrom(
            msg.sender,
            CreateClaimParams({
                creditor: offer.creditor,
                debtor: offer.debtor,
                claimAmount: offer.loanAmount, //claim amount is just loan amount now
                dueBy: offer.termLength + block.timestamp,
                description: offer.description,
                token: offer.token,
                controller: address(this),
                feePayer: offer.feePayer,
                binding: ClaimBinding.Bound,
                payerReceivesClaimOnPayment: offer.payerReceivesClaimOnPayment
            }),
            offer.metadata
        );

        ERC20(offer.token).safeTransfer(offer.debtor, offer.loanAmount);

        if (initialPayment > 0) {
            // put the payment towards the claim amount
        }

        emit LoanOfferAccepted(offerId, claimId, block.timestamp);
    }
}
