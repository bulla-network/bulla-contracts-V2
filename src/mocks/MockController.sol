// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {IBullaClaim} from "../interfaces/IBullaClaim.sol";
import {ClaimBinding, CreateClaimParams} from "../types/Types.sol";

contract MockController {
    IBullaClaim public bullaClaim;

    // For testing: allows specifying who the controller is acting on behalf of
    address public currentUser;

    constructor(address _bullaClaim) {
        bullaClaim = IBullaClaim(_bullaClaim);
    }

    function setCurrentUser(address user) external {
        currentUser = user;
    }

    function createClaim(CreateClaimParams calldata params) external payable returns (uint256) {
        return bullaClaim.createClaimFrom{value: msg.value}(currentUser, params);
    }

    function cancelClaim(uint256 claimId, string calldata note) external {
        bullaClaim.cancelClaimFrom(currentUser, claimId, note);
    }

    function payClaim(uint256 claimId, uint256 amount) external payable {
        bullaClaim.payClaimFrom{value: msg.value}(currentUser, claimId, amount);
    }

    function updateBinding(uint256 claimId, ClaimBinding binding) external {
        bullaClaim.updateBindingFrom(currentUser, claimId, binding);
    }

    function impairClaim(uint256 claimId) external {
        bullaClaim.impairClaimFrom(currentUser, claimId);
    }

    function markClaimAsPaid(uint256 claimId) external {
        bullaClaim.markClaimAsPaidFrom(currentUser, claimId);
    }
}
