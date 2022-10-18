//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

contract PenalizedClaimTest is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    PenalizedClaim public penalizedClaim;

    address creditor = address(0x01);
    address debtor = address(0x02);
    address feeReceiver = address(0xFee);

    function setUp() public {
        weth = new WETH();

        (bullaClaim,) = (new Deployer()).deploy_test(address(this), address(0xfee), LockState.Unlocked, 0);

        penalizedClaim = new PenalizedClaim(address(bullaClaim));

        bullaClaim.registerExtension(address(penalizedClaim));

        vm.deal(debtor, 10 ether);
    }

    // deploy contracts, setup extension, ensure cannot call create, cancel, or pay directly on BullaClaim

    function testFeeWorks() public {
        uint256 claimId = penalizedClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(penalizedClaim),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.BindingPending
            })
        );

        vm.prank(debtor);
        penalizedClaim.acceptClaim(claimId);

        vm.warp(block.timestamp + 2 days);

        vm.prank(debtor);
        penalizedClaim.payClaim{value: 1.05 ether}(claimId, 1.05 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Paid);
    }

    function testCannotBypassDelegator() public {
        uint256 claimId = penalizedClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(penalizedClaim),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.BindingPending
            })
        );

        vm.startPrank(debtor);

        vm.expectRevert(abi.encodeWithSignature("ClaimDelegated(uint256,address)", claimId, address(penalizedClaim)));
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectRevert(abi.encodeWithSignature("ClaimDelegated(uint256,address)", claimId, address(penalizedClaim)));
        bullaClaim.payClaim{value: 0.5 ether}(claimId, 0.5 ether);

        vm.expectRevert(abi.encodeWithSignature("ClaimDelegated(uint256,address)", claimId, address(penalizedClaim)));
        bullaClaim.cancelClaim(claimId, "Nahhhh");
    }
}
