// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {BullaClaim, CreateClaimParams, BullaClaim} from "contracts/BullaClaim.sol";

// naive implementation of a bullaExtension and a controller that penalizes users for paying late:
//   note: all claim creation / mutation methods like createClaim, payClaim, acceptClaim,
//   and cancelClaim have to be routed through this contract.

contract PenalizedClaim {
    using SafeTransferLib for *;

    uint256 LATE_FEE_BPS = 500;
    BullaClaim bullaClaim;

    error NotController(address controller);

    constructor(address _bullaClaimAddress) {
        bullaClaim = BullaClaim(_bullaClaimAddress);
    }

    function createClaim(CreateClaimParams calldata claimParams) public returns (uint256) {
        _checkController(claimParams.controller);
        return bullaClaim.createClaimFrom(msg.sender, claimParams);
    }

    function payClaim(uint256 claimId, uint256 amount) public payable {
        Claim memory claim = bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        uint256 amountToPay = amount;

        if (claim.binding == ClaimBinding.Bound && claim.dueBy < block.timestamp) {
            uint256 lateFee = (LATE_FEE_BPS * claim.claimAmount) / 10000;
            amountToPay -= lateFee;
            address creditor = bullaClaim.ownerOf(claimId);

            claim.token == address(0)
                ? creditor.safeTransferETH(lateFee)
                : ERC20(claim.token).safeTransferFrom(msg.sender, creditor, lateFee);
        }

        bullaClaim.payClaimFrom{value: claim.token == address(0) ? amountToPay : 0}(msg.sender, claimId, amountToPay);
    }

    function cancelClaim(uint256 claimId, string calldata note) public {
        Claim memory claim = bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        bullaClaim.cancelClaimFrom(msg.sender, claimId, note);
    }

    function acceptClaim(uint256 claimId) public {
        bullaClaim.updateBindingFrom(msg.sender, claimId, ClaimBinding.Bound);
    }

    function _checkController(address _controller) internal view {
        if (_controller != address(this)) {
            revert NotController(_controller);
        }
    }
}
