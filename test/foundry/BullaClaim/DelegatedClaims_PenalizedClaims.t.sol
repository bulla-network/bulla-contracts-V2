// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";

contract TestPenalizedClaim is Test {
    WETH public weth;
    BullaClaimV2 public bullaClaim;
    EIP712Helper public sigHelper;
    PenalizedClaim public penalizedClaim;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    function setUp() public {
        weth = new WETH();

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        penalizedClaim = new PenalizedClaim(address(bullaClaim));

        vm.deal(debtor, 10 ether);
    }

    // deploy contracts, setup extension, ensure cannot call create, cancel, or pay directly on BullaClaim
    function testFeeWorks() public {
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(penalizedClaim),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(penalizedClaim),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.startPrank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withBinding(
                ClaimBinding.BindingPending
            ).build()
        );
        vm.stopPrank();

        vm.prank(debtor);
        penalizedClaim.acceptClaim(claimId);

        vm.warp(block.timestamp + 2 days);

        vm.prank(debtor);
        penalizedClaim.payClaim{value: 1.05 ether}(claimId, 1.05 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Paid);
    }

    function testCannotBypassController() public {
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(penalizedClaim),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(penalizedClaim),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.startPrank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withBinding(
                ClaimBinding.BindingPending
            ).build()
        );
        vm.stopPrank();

        vm.startPrank(debtor);

        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, debtor));
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, debtor));
        bullaClaim.payClaim{value: 0.5 ether}(claimId, 0.5 ether);

        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, debtor));
        bullaClaim.cancelClaim(claimId, "Nahhhh");
    }
}
