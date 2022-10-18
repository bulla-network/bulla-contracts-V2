//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {Status, ClaimBinding, FeePayer} from "contracts/types/Enums.sol";

struct ClaimMetadata {
    string tokenURI;
    string attachmentURI;
}

struct ClaimStorage {
    uint128 claimAmount;
    uint128 paidAmount;
    Status status;
    ClaimBinding binding; // the debtor can allow themselves to be bound to a claim, which makes a claim unrejectable
    FeePayer feePayer;
    // if feePayer = Debtor:
    //      the payer is charged the fee and the creditor receives the _exact_ amount listed on the claim.
    // if feePayer = Creditor:
    //      the creditor pays the fee, meaning they will receive claimAmount - fee
    uint16 feeCalculatorId;
    uint40 dueBy;
    address debtor;
    address token; // the token address that the claim is denominated in. NOTE: if this token is address(0), we treat this as a native token
    address delegator;
} // takes 4 storage slots

// a cheaper struct for working / manipulating memory (unpacked is cheapter)
struct Claim {
    uint256 claimAmount;
    uint256 paidAmount;
    Status status;
    ClaimBinding binding;
    FeePayer feePayer;
    address debtor;
    uint256 feeCalculatorId;
    uint256 dueBy;
    address token;
    address delegator;
}
