// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {ClaimBinding, FeePayer, Claim} from "contracts/types/Types.sol";
import {IBullaFeeCalculator} from "contracts/interfaces/IBullaFeeCalculator.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Owned} from "solmate/auth/Owned.sol";

/// @title BullaFeeCalculator
/// @author @colinnielsen
/// @notice V1 fee calculator that is ownable and calculates a flat fee
contract BullaFeeCalculator is IBullaFeeCalculator, Owned {
    using FixedPointMathLib for uint256;

    uint256 public feeBPS;

    constructor(uint256 _fee) Owned(msg.sender) {
        feeBPS = _fee;
    }

    // returns the fee in wei
    function calculateFee(
        uint256,
        address,
        address,
        address,
        uint256 paymentAmount,
        uint256 claimAmount,
        uint256,
        uint256,
        ClaimBinding,
        FeePayer feePayer
    ) external view returns (uint256) {
        if (feePayer == FeePayer.Creditor) {
            return paymentAmount.mulDivDown(feeBPS, 10000);
        } else {
            uint256 claimFee = claimAmount.mulDivDown(feeBPS, 10000);

            return claimFee.mulDivDown(paymentAmount, (claimFee + claimAmount));
        }
    }

    // the full amountRequired to pay a claim
    function fullPaymentAmount(
        uint256,
        address,
        address,
        address,
        uint256 claimAmount,
        uint256 paidAmount,
        uint256,
        ClaimBinding,
        FeePayer feePayer
    ) external view returns (uint256) {
        uint256 amountRemaining = claimAmount - paidAmount;

        return amountRemaining + (feePayer == FeePayer.Debtor ? amountRemaining.mulDivDown(feeBPS, 10000) : 0);
    }

    function updateFee(uint256 newFeeBPS) external onlyOwner {
        feeBPS = newFeeBPS;
    }
}
