// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

struct InterestConfig {
    uint16 interestRateBps;
    uint16 numberOfPeriodsPerYear;
}

struct InterestComputationState {
    uint256 accruedInterest;
    uint256 latestPeriodNumber;
}

uint16 constant MAX_DAYS_PER_YEAR = 365;
uint256 constant SECONDS_PER_YEAR = 31536000;
uint256 constant MAX_BPS = 10_000;
uint256 constant ONE = 10 ** 18;

library CompoundInterestLib {
    error InvalidPeriodsPerYear();

    /**
     * @notice Validates interest configuration
     * @param config The interest configuration to validate
     */
    function validateInterestConfig(InterestConfig memory config) public pure {
        // Skip validation if interest is disabled
        if (config.interestRateBps == 0) {
            return;
        }

        if (config.numberOfPeriodsPerYear == 0 || config.numberOfPeriodsPerYear > MAX_DAYS_PER_YEAR) {
            revert InvalidPeriodsPerYear();
        }
    }

    /**
     * @notice Computes the interest for a given principal, dueBy date, and interest configuration
     * @dev An implication is made that if remainingPrincipal is 0, there cannot be any interest accrued
     * @param remainingPrincipal The remaining principal to compute interest for
     * @param dueBy The dueBy date
     * @param config The interest configuration
     */
    function computeInterest(
        uint256 remainingPrincipal,
        uint256 dueBy,
        InterestConfig memory config,
        InterestComputationState memory state
    ) public view returns (InterestComputationState memory) {
        uint256 currentTimestamp = block.timestamp;

        if (
            config.interestRateBps == 0 || config.numberOfPeriodsPerYear == 0
                || config.numberOfPeriodsPerYear > MAX_DAYS_PER_YEAR || dueBy == 0 || dueBy >= currentTimestamp
                || remainingPrincipal == 0
        ) {
            return state;
        }

        uint256 numberOfPeriodsPerYear = uint256(config.numberOfPeriodsPerYear);

        // Calculate the number of periods since the dueBy date
        uint256 secondsPerPeriod = SECONDS_PER_YEAR / numberOfPeriodsPerYear;
        uint256 currentPeriodNumber = currentTimestamp > dueBy ? (currentTimestamp - dueBy) / secondsPerPeriod : 0;

        uint256 periodsElapsed =
            currentPeriodNumber > state.latestPeriodNumber ? currentPeriodNumber - state.latestPeriodNumber : 0;
        // If no complete period has elapsed, return the previously accrued interest
        if (periodsElapsed == 0) {
            return state;
        }

        // Calculate interest rate per period scaled to 18 decimal places
        uint256 ratePerPeriodScaled =
            Math.mulDiv(uint256(config.interestRateBps), ONE, numberOfPeriodsPerYear * MAX_BPS);

        // Calculate compound factor: (1 + r)^n
        // Using the formula: x^n = exp(n * ln(x))
        uint256 compoundFactor = _calculateCompoundFactor(ONE + ratePerPeriodScaled, periodsElapsed);

        // Apply compound factor to current total amount
        uint256 totalWithInterest = Math.mulDiv(remainingPrincipal + state.accruedInterest, compoundFactor, ONE);

        // remove the principal from the total amount to get the current total accrued interest
        uint256 totalAccruedInterest = totalWithInterest - remainingPrincipal;

        // Add to previously accrued interest
        return
            InterestComputationState({accruedInterest: totalAccruedInterest, latestPeriodNumber: currentPeriodNumber});
    }

    /**
     * @dev Calculate (1 + r)^n using binomial approximation
     * For practical interest rates, this approximation is sufficient
     * For better precision with larger rates, use a more sophisticated algorithm
     */
    function _calculateCompoundFactor(uint256 base, uint256 exponent) private pure returns (uint256 result) {
        result = ONE;

        while (exponent > 0) {
            if (exponent % 2 == 1) {
                result = (result * base) / ONE;
            }
            base = (base * base) / ONE;
            exponent /= 2;
        }

        return result;
    }
}
