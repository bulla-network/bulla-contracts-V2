// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {LoanRequestParams} from "../interfaces/IBullaFrendLendV2.sol";

/**
 * @title LoanOfferIdLib
 * @notice Library for computing unique, deterministic loan offer IDs
 * @dev Uses EIP-712 style hashing with domain separator and nonce to prevent re-org attacks
 */
library LoanOfferIdLib {
    // Type hash for loan offer parameters
    bytes32 public constant LOAN_OFFER_TYPEHASH = keccak256(
        "LoanOffer(uint256 termLength,uint256 loanAmount,address creditor,address debtor,address token,uint256 impairmentGracePeriod,uint256 expiresAt,address callbackContract,bytes4 callbackSelector,string description,uint256 interestRateBps,uint256 compoundingFrequency,uint256 nonce)"
    );

    /**
     * @notice Compute the unique loan offer ID from parameters and nonce
     * @param offer The loan offer parameters
     * @param nonce The nonce for this user
     * @param domainSeparator The EIP-712 domain separator for the contract
     * @return The unique uint256 offer ID
     */
    function computeLoanOfferId(LoanRequestParams calldata offer, uint256 nonce, bytes32 domainSeparator)
        internal
        pure
        returns (uint256)
    {
        // Encode in parts to avoid stack too deep
        bytes32 part1 = keccak256(
            abi.encode(
                LOAN_OFFER_TYPEHASH, offer.termLength, offer.loanAmount, offer.creditor, offer.debtor, offer.token
            )
        );

        bytes32 part2 = keccak256(
            abi.encode(
                offer.impairmentGracePeriod,
                offer.expiresAt,
                offer.callbackContract,
                offer.callbackSelector,
                keccak256(bytes(offer.description))
            )
        );

        bytes32 part3 = keccak256(
            abi.encode(offer.interestConfig.interestRateBps, offer.interestConfig.numberOfPeriodsPerYear, nonce)
        );

        bytes32 structHash = keccak256(abi.encodePacked(part1, part2, part3));

        return uint256(keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }
}
