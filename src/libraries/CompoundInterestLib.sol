// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeMath.sol";

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
uint256 constant MAX_MBPS = 100_00_000;
uint256 constant ONE = 10**18;

library CompoundInterestLib {
    using SafeMath for uint256;
    
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
     * @dev We assume that the interest configuration has been validated and is immutable
     * @param remainingPrincipal The remaining principal to compute interest for
     * @param dueBy The dueBy date
     * @param lastPeriodNumber The last period number
     * @param config The interest configuration
    */
    function computeInterest(uint256 remainingPrincipal, uint256 dueBy, uint256 lastPeriodNumber, InterestConfig memory config, InterestComputationState memory state) public view returns (InterestComputationState memory) {
        uint256 currentTimestamp = block.timestamp;

        if (config.interestRateBps == 0 
            || dueBy == 0
            || dueBy >= currentTimestamp) {
            return state;
        }
        
        // Calculate the number of periods since the dueBy date
        uint256 secondsPerPeriod = SECONDS_PER_YEAR / config.numberOfPeriodsPerYear;
        // round up the period
        uint256 currentPeriodNumber = Math.ceilDiv(currentTimestamp - dueBy, secondsPerPeriod);
        
        uint256 periodsElapsed = currentPeriodNumber - lastPeriodNumber;
        // If no complete period has elapsed, return the previously accrued interest
        if (periodsElapsed == 0) {
            return state;
        }
        
        // Calculate interest rate per period scaled to 18 decimal places
        uint256 ratePerPeriodScaled = Math.mulDiv(config.interestRateBps, ONE, config.numberOfPeriodsPerYear);
        
        // Calculate compound factor: (1 + r)^n
        // Using the formula: x^n = exp(n * ln(x))
        uint256 compoundFactor = _calculateCompoundFactor(ONE + ratePerPeriodScaled, periodsElapsed);

        uint256 amountToCompound = remainingPrincipal + state.accruedInterest;
        
        // Apply compound factor to current total amount
        uint256 totalWithInterest = Math.mulDiv(amountToCompound, compoundFactor, ONE);

        // remove the principal from the total amount to get the current total accrued interest
        uint256 totalAccruedInterest = totalWithInterest - remainingPrincipal;
        
        // Add to previously accrued interest
        return InterestComputationState({
            accruedInterest: totalAccruedInterest,
            latestPeriodNumber: currentPeriodNumber
        });
    }
    
    /**
     * @dev Calculate (1 + r)^n using binomial approximation
     * For practical interest rates, this approximation is sufficient
     * For better precision with larger rates, use a more sophisticated algorithm
     */
    function _calculateCompoundFactor(uint256 base, uint256 exponent) private pure returns (uint256 result) {
        result = ONE;
        
        // For small exponents, calculate directly
        if (exponent <= 10) {
            uint256 term = ONE;
            
            for (uint256 i = 0; i < exponent; i++) {
                term = Math.mulDiv(term, base, ONE);
                result = term;
            }
            
            return result;
        }
        
        // For larger exponents, use square and multiply algorithm
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
