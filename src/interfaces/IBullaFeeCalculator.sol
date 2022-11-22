// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {ClaimBinding, FeePayer, Claim} from "contracts/types/Types.sol";

interface IBullaFeeCalculator {
    /// @notice calculate a fee for a claim
    /// @dev the fee is always calculated in the underlying token
    function calculateFee(
        uint256 claimId,
        address payer,
        address creditor,
        address debtor,
        uint256 paymentAmount,
        uint256 claimAmount,
        uint256 paidAmount,
        uint256 dueBy,
        ClaimBinding claimBinding,
        FeePayer feePayer
    ) external view returns (uint256);

    /// @notice calculate full payment amount
    function fullPaymentAmount(
        uint256 claimId,
        address payer,
        address creditor,
        address debtor,
        uint256 claimAmount,
        uint256 paidAmount,
        uint256 dueBy,
        ClaimBinding claimBinding,
        FeePayer feePayer
    ) external view returns (uint256);
}
