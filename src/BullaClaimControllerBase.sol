// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "contracts/interfaces/IBullaClaim.sol";
import "contracts/types/Types.sol";

abstract contract BullaClaimControllerBase {
    IBullaClaim public immutable _bullaClaim;

    constructor(address bullaClaimAddress) {
        _bullaClaim = IBullaClaim(bullaClaimAddress);
    }

    function _checkController(address controller) internal view {
        if (controller != address(this)) {
            revert IBullaClaim.NotController(msg.sender);
        }
    }
}
