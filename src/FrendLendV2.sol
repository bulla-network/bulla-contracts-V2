// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {BullaClaim, CreateClaimParams, ClaimBinding, FeePayer, ClaimMetadata} from "contracts/BullaClaim.sol";

uint256 constant MAX_BPS = 10_000;

struct LoanOffer {
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
    /// the address which receives fees
    address public feeReceiver;
    /// commitment to loan offers
    mapping(bytes32 => bool) public loanOffers;

    event LoanOffered(bytes32 indexed loanId, address indexed offeredBy, LoanOffer loanOffer, uint256 blocktime);
    event LoanOfferAccepted(bytes32 indexed loanId, uint256 indexed claimId, uint256 blocktime);
    event LoanOfferRejected(bytes32 indexed loanId, address indexed rejectedBy, uint256 blocktime);

    error INCORRECT_FEE();
    error NOT_CREDITOR();
    error NOT_DEBTOR();
    error NOT_CREDITOR_OR_DEBTOR();
    error NOT_ADMIN();
    error NO_LOAN_OFFER();
    error LOAN_CANNOT_BE_ACCEPTED();
    error INVALID_TERM_LENGTH();
    error WITHDRAWAL_FAILED();
    error TRANSFER_FAILED();

    constructor(BullaClaim _bullaClaim, address _admin, uint256 _fee, address _feeReceiver) {
        bullaClaim = _bullaClaim;
        admin = _admin;
        fee = _fee;
        feeReceiver = _feeReceiver;
    }

    ////// ADMIN FUNCTIONS //////

    // function setFee(uint256 _newFee) public {
    //     if (msg.sender != admin) revert NOT_ADMIN();

    //     fee = _newFee;
    // }

    // function setFeeReceiver(address _feeReceiver) public {
    //     if (msg.sender != admin) revert NOT_ADMIN();

    //     feeReceiver = _feeReceiver;
    // }

    ////// USER FUNCTIONS //////

    function offerLoan(LoanOffer calldata offer) public returns (bytes32) {
        // if (msg.value != fee) revert INCORRECT_FEE();
        if (msg.sender != offer.creditor) revert NOT_CREDITOR();
        if (offer.termLength == 0) revert INVALID_TERM_LENGTH();

        bytes32 offerId = keccak256(abi.encode(offer));
        loanOffers[offerId] = true;

        emit LoanOffered(offerId, msg.sender, offer, block.timestamp);

        return offerId;
    }

    function rejectLoanOffer(LoanOffer calldata offer) public {
        bytes32 offerId = keccak256(abi.encode(offer));
        if (msg.sender != offer.creditor && msg.sender != offer.debtor) {
            revert NOT_CREDITOR_OR_DEBTOR();
        }

        loanOffers[offerId] = false;

        emit LoanOfferRejected(offerId, msg.sender, block.timestamp);
    }

    function acceptLoan(LoanOffer calldata offer, uint256 initialPayment) public {
        bytes32 offerId = keccak256(abi.encode(offer));
        if (!loanOffers[offerId]) revert NO_LOAN_OFFER();
        if (msg.sender != offer.debtor) revert NOT_DEBTOR();

        delete loanOffers[offerId];

        uint256 claimId = bullaClaim.createClaimWithMetadataFrom(
            msg.sender,
            CreateClaimParams({
                creditor: offer.creditor,
                debtor: offer.debtor,
                claimAmount: offer.loanAmount, // claim amount is just loan amount now
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
