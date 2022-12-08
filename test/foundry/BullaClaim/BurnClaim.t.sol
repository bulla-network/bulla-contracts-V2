// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    FeePayer,
    LockState,
    CreateClaimParams,
    ClaimMetadata
} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestBurnClaim is Test {
    BullaClaim public bullaClaim;

    address alice = address(0xA11cE);
    address charlie = address(0xC44511E);

    address creditor = address(0x01);
    address debtor = address(0x02);

    function setUp() public {
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(alice, "ALICE");

        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xFEE),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        vm.deal(debtor, 1 ether);
    }

    function _newClaim() internal returns (uint256 claimId) {
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testBurnPaidClaim() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.startPrank(debtor);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);

        // set approvals to ensure approval is cleared
        bullaClaim.approve(alice, claimId);
        bullaClaim.setApprovalForAll(alice, true);

        assertEq(bullaClaim.balanceOf(debtor), 1);
        assertEq(bullaClaim.ownerOf(claimId), debtor);

        bullaClaim.burn(claimId);

        assertEq(bullaClaim.getApproved(claimId), address(0));

        vm.expectRevert("NOT_MINTED");
        assertEq(bullaClaim.ownerOf(claimId), address(0));

        // wrong_from means the debtor is no longer the owner, because the owner is technically address(0) when burned
        vm.expectRevert("WRONG_FROM");
        bullaClaim.transferFrom(debtor, creditor, claimId);
        vm.stopPrank();

        // ensure alice's approval has been cleared
        vm.startPrank(alice);
        vm.expectRevert("WRONG_FROM");
        bullaClaim.transferFrom(debtor, creditor, claimId);
    }

    function testCannotDoubleBurn() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.startPrank(debtor);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);
        bullaClaim.burn(claimId);

        vm.expectRevert("NOT_MINTED");
        bullaClaim.burn(claimId);
    }

    function testCannotBurnPendingClaim() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.prank(creditor);
        vm.expectRevert(BullaClaim.ClaimPending.selector);
        bullaClaim.burn(claimId);
    }

    function testCannotBurnRescindedClaim() public {
        vm.startPrank(creditor);
        uint256 claimId = _newClaim();

        bullaClaim.cancelClaim(claimId, "no thanks");
        vm.expectRevert(BullaClaim.ClaimPending.selector);
        bullaClaim.burn(claimId);
        vm.stopPrank();
    }

    function testCannotBurnRejectedClaim() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.prank(debtor);
        bullaClaim.payClaim{value: 0.5 ether}(claimId, 0.5 ether);

        vm.prank(creditor);
        vm.expectRevert(BullaClaim.ClaimPending.selector);
        bullaClaim.burn(claimId);
    }

    function testCannotBurnRepayingClaim() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "no thanks");

        vm.prank(creditor);
        vm.expectRevert(BullaClaim.ClaimPending.selector);
        bullaClaim.burn(claimId);
    }

    function testCannotBurnIfLocked() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        bullaClaim.setLockState(LockState.Locked);

        vm.expectRevert(BullaClaim.Locked.selector);
        vm.prank(creditor);
        bullaClaim.burn(claimId);
    }

    function testCanBurnIfPartiallyLocked() public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.prank(debtor);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);

        bullaClaim.setLockState(LockState.NoNewClaims);

        vm.prank(debtor);
        bullaClaim.burn(claimId);
    }

    function testCannotBurnIfNotOwner(address sender) public {
        vm.prank(creditor);
        uint256 claimId = _newClaim();

        vm.prank(debtor);
        bullaClaim.payClaim{value: 1 ether}(claimId, 1 ether);

        vm.expectRevert(BullaClaim.NotOwner.selector);
        vm.prank(sender);
        bullaClaim.burn(claimId);
    }
}
