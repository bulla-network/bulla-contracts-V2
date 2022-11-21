// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;
// TODO update license

import {FeePayer, Claim} from "../types/Types.sol";
import {BullaClaim} from "../BullaClaim.sol";
import {IBullaFeeCalculator} from "../interfaces/IBullaFeeCalculator.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

library BullaHelpers {
    // todo: add checks for controllers and route this request through their logic
    /// @notice gets the paymentAmount required for a claim to be fully paid
    function fullPaymentAmount(BullaClaim bullaClaim, address payer, uint256 claimId) public view returns (uint256) {
        Claim memory claim = bullaClaim.getClaim(claimId);
        IBullaFeeCalculator feeCalculator = bullaClaim.feeCalculators(uint256(claim.feeCalculatorId));

        address creditor = bullaClaim.ownerOf(claimId);
        return address(feeCalculator) != address(0)
            ? feeCalculator.fullPaymentAmount(
                claimId,
                payer,
                creditor,
                claim.debtor,
                claim.claimAmount,
                claim.paidAmount,
                claim.dueBy,
                claim.binding,
                claim.feePayer
            )
            : claim.claimAmount - claim.paidAmount;
    }

    function calculateFee(BullaClaim bullaClaim, address payer, uint256 claimId, uint256 paymentAmount)
        public
        view
        returns (uint256)
    {
        Claim memory claim = bullaClaim.getClaim(claimId);
        IBullaFeeCalculator feeCalculator = bullaClaim.feeCalculators(uint256(claim.feeCalculatorId));

        address creditor = bullaClaim.ownerOf(claimId);
        return address(feeCalculator) != address(0)
            ? feeCalculator.calculateFee(
                claimId,
                payer,
                creditor,
                claim.debtor,
                paymentAmount,
                claim.claimAmount,
                claim.paidAmount,
                claim.dueBy,
                claim.binding,
                claim.feePayer
            )
            : 0;
    }
}
