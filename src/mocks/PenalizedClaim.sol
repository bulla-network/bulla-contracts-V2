//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Claim, ClaimBinding} from "contracts/types/Structs.sol";
import {BullaClaim, CreateClaimParams, BullaClaim} from "contracts/BullaClaim.sol";

// naive implementation of a bullaExtension and a delegator that penalizes users for paying late:
//   note: all claim creation / mutation methods like createClaim, payClaim, acceptClaim,
//   and cancelClaim have to be routed through this contract.

contract PenalizedClaim {
    using SafeTransferLib for *;

    uint256 LATE_FEE_BPS = 500;
    BullaClaim bullaClaim;

    error NotDelegator(address delegator);

    constructor(address _bullaClaimAddress) {
        bullaClaim = BullaClaim(_bullaClaimAddress);
    }

    function createClaim(CreateClaimParams calldata claimParams) public returns (uint256) {
        _checkDelegator(claimParams.delegator);
        return bullaClaim.createClaimFrom(msg.sender, claimParams);
    }

    function payClaim(uint256 claimId, uint256 amount) public payable {
        Claim memory claim = bullaClaim.getClaim(claimId);
        _checkDelegator(claim.delegator);

        uint256 amountToPay = amount;

        if (claim.binding == ClaimBinding.Bound && claim.dueBy < block.timestamp) {
            uint256 lateFee = (LATE_FEE_BPS * claim.claimAmount) / 10000;
            amountToPay -= lateFee;
            address creditor = bullaClaim.ownerOf(claimId);

            claim.token == address(0)
                ? creditor.safeTransferETH(lateFee)
                : ERC20(claim.token).safeTransferFrom(msg.sender, creditor, lateFee);
        }

        bullaClaim.payClaimFrom{value: amountToPay}(msg.sender, claimId, amountToPay);
    }

    // function cancelClaim(uint256 claimId, string calldata note) public {
    //     Claim memory claim = bullaClaim.getClaim(claimId);
    //     _checkDelegator(claim.delegator);

    //     if (claim.binding == ClaimBinding.Bound && claim.debtor == msg.sender) {
    //         revert BullaClaim.ClaimBound(claimId);
    //     }

    //     bullaClaim.cancelClaimFrom(msg.sender, claimId, note);
    // }

    // function acceptClaim(uint256 claimId) public {
    //     bullaClaim.updateBindingFrom(msg.sender, claimId, ClaimBinding.Bound);
    // }

    function _checkDelegator(address _delegator) internal view {
        if (_delegator != address(this)) {
            revert NotDelegator(_delegator);
        }
    }
}
