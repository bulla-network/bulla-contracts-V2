// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/types/Types.sol";

abstract contract BullaClaimControllerBase {
    IBullaClaim internal immutable _bullaClaim;

    constructor(address bullaClaimAddress) {
        _bullaClaim = IBullaClaim(bullaClaimAddress);
    }

    function _checkController(address controller) internal view {
        if (controller != address(this)) {
            revert IBullaClaim.NotController(controller);
        }
    }
}
