//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Enums.sol";

struct CreateClaimParams {
    address creditor;
    address debtor;
    uint256 claimAmount;
    uint256 dueBy;
    string description;
    address token;
    address delegator;
    FeePayer feePayer;
    ClaimBinding binding;
}
