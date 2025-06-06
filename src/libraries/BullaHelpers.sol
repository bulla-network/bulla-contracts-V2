// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {Claim} from "../types/Types.sol";
import {BullaClaim} from "../BullaClaim.sol";

library BullaHelpers {
    /// @notice gets the paymentAmount required for a claim to be fully paid
    function getRemainingPrincipalAmount(BullaClaim bullaClaim, uint256 claimId) public view returns (uint256) {
        Claim memory claim = bullaClaim.getClaim(claimId);

        return claim.claimAmount - claim.paidAmount;
    }
}
