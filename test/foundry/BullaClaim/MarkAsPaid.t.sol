// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Claim, Status, ClaimBinding, CreateClaimParams, ClaimMetadata, LockState} from "contracts/types/Types.sol";
import {BullaClaimV2, CreateClaimApprovalType} from "contracts/BullaClaimV2.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";

contract TestMarkAsPaid is BullaClaimTestHelper {
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 randomPK = uint256(0x03);
    uint256 controllerPK = uint256(0x04);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address randomUser = vm.addr(randomPK);
    address controller = vm.addr(controllerPK);

    event ClaimMarkedAsPaid(uint256 indexed claimId);

    function setUp() public {
        weth = new WETH();
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);
        vm.deal(controller, 10 ether);

        vm.prank(creditor);
        weth.deposit{value: 10 ether}();
        vm.prank(debtor);
        weth.deposit{value: 10 ether}();
        vm.prank(controller);
        weth.deposit{value: 10 ether}();

        _permitCreateClaim(creditorPK, controller, 1);
    }

    /*///////////////////////////////////////////////////////////////
                            HAPPY PATH TESTS
    //////////////////////////////////////////////////////////////*/

    function testMarkAsPaid_Success() public {
        // Create a pending claim
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        vm.expectEmit(true, true, false, true);
        emit ClaimMarkedAsPaid(claimId);

        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be marked as paid");
    }

    function testMarkAsPaid_FromRepaying() public {
        // Create claim
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Make partial payment to put claim in repaying status
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId, 0.5 ether);
        vm.stopPrank();

        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimBefore.status), uint256(Status.Repaying), "Claim should be repaying");

        vm.expectEmit(true, true, false, true);
        emit ClaimMarkedAsPaid(claimId);

        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Paid), "Claim should be marked as paid");
    }

    function testMarkAsPaidFrom_WithController() public {
        PenalizedClaim penalizedClaim = new PenalizedClaim(address(bullaClaim));

        // Setup approval for penalizedClaim to create claims
        _permitCreateClaim(creditorPK, address(penalizedClaim), 1);

        vm.startPrank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();

        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(claimBefore.controller, address(penalizedClaim), "Controller should be set");

        vm.expectEmit(true, true, false, true);
        emit ClaimMarkedAsPaid(claimId);

        vm.prank(address(penalizedClaim));
        bullaClaim.markClaimAsPaidFrom(creditor, claimId);

        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Paid), "Claim should be marked as paid");
    }

    function testMarkAsPaid_FromImpaired() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period and impair the claim
        vm.warp(block.timestamp + 38 days);
        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimBefore.status), uint256(Status.Impaired), "Claim should be impaired");

        // Now mark it as paid
        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Paid), "Claim should be marked as paid");
    }

    function testMarkAsPaid_WithSubstantialPartialPayment() public {
        // Create a claim
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Pay 99% of the claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 0.99 ether);
        bullaClaim.payClaim(claimId, 0.99 ether);
        vm.stopPrank();

        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimBefore.status), uint256(Status.Repaying), "Claim should be repaying");
        assertEq(claimBefore.paidAmount, 0.99 ether, "Paid amount should be 0.99 ether");

        // Mark the claim as paid despite the small remaining balance
        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Paid), "Claim should be marked as paid");
        assertEq(claimAfter.paidAmount, 0.99 ether, "Paid amount should remain 0.99 ether");
    }

    /*///////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotMarkAsPaid_NotCreditor() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Debtor cannot mark as paid
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaClaim.markClaimAsPaid(claimId);

        // Random user cannot mark as paid
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaid_WrongController() public {
        PenalizedClaim penalizedClaim = new PenalizedClaim(address(bullaClaim));

        // Setup approval for penalizedClaim to create claims
        _permitCreateClaim(creditorPK, address(penalizedClaim), 1);

        vm.startPrank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();

        // Direct call should fail when controller is set
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, creditor));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaidFrom_NotApproved() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.markClaimAsPaidFrom(creditor, claimId);
    }

    /*///////////////////////////////////////////////////////////////
                        STATE VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotMarkAsPaid_WrongStatus() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Fully pay the claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 1 ether);
        bullaClaim.payClaim(claimId, 1 ether);
        vm.stopPrank();

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be paid");

        // Cannot mark as paid a claim that's already paid
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaid_RejectedClaim() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Reject the claim
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "Rejected by debtor");

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Rejected), "Claim should be rejected");

        // Cannot mark as paid a rejected claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaid_RescindedClaim() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Rescind the claim
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "Rescinded by creditor");

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Rescinded), "Claim should be rescinded");

        // Cannot mark as paid a rescinded claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaid_AlreadyMarkedAsPaid() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Mark as paid first time
        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be marked as paid");

        // Cannot mark as paid again
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaid_ContractLocked() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Lock the contract
        bullaClaim.setLockState(LockState.Locked);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.Locked.selector));
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testCannotMarkAsPaid_NotMinted() public {
        uint256 nonExistentClaimId = 999;

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotMinted.selector));
        bullaClaim.markClaimAsPaid(nonExistentClaimId);
    }

    /*///////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    // Tests that binding cannot be updated on a paid claim, as paid claims represent completed obligations
    function testUpdateBindingMarkedAsPaidClaim_Fails() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Mark as paid
        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        // Should not be able to update binding on paid claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);
    }

    /*///////////////////////////////////////////////////////////////
                            EVENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testMarkAsPaid_EventEmission() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        vm.expectEmit(true, true, false, true);
        emit ClaimMarkedAsPaid(claimId);

        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);
    }

    function testMarkAsPaidFrom_EventEmission() public {
        vm.startPrank(controller);
        uint256 claimId = _newClaimFrom({_from: creditor, _creditor: creditor, _debtor: debtor});
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit ClaimMarkedAsPaid(claimId);

        vm.prank(controller);
        bullaClaim.markClaimAsPaidFrom(creditor, claimId);
    }

    /*///////////////////////////////////////////////////////////////
                        NFT TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function testMarkAsPaid_AfterNFTTransfer() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Transfer NFT to another address
        vm.prank(creditor);
        bullaClaim.transferFrom(creditor, randomUser, claimId);

        assertEq(bullaClaim.ownerOf(claimId), randomUser, "NFT should be transferred");

        // New owner should be able to mark as paid
        vm.prank(randomUser);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be marked as paid");

        // Original creditor should not be able to mark as paid
        uint256 claimId2 = _newClaim(creditor, creditor, debtor);

        vm.prank(creditor);
        bullaClaim.transferFrom(creditor, randomUser, claimId2);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaClaim.markClaimAsPaid(claimId2);
    }

    /*///////////////////////////////////////////////////////////////
                        EDGE CASES AND FUZZING
    //////////////////////////////////////////////////////////////*/

    function testMarkAsPaid_EdgeCases() public {
        // Test with maximum uint128 amount
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(uint256(type(uint128).max)).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Large claim should be marked as paid");
    }

    function test_FUZZ_markAsPaid(uint256 pk, address _debtor, uint128 claimAmount, address token, uint8 bindingType)
        public
    {
        vm.assume(privateKeyValidity(pk));
        vm.assume(claimAmount > 0);
        vm.assume(bindingType <= 2); // Valid binding types

        address _creditor = vm.addr(pk);
        ClaimBinding binding = ClaimBinding(bindingType);

        // Create claim with fuzzed parameters
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor)
            .withClaimAmount(claimAmount).withToken(token).withBinding(binding).build();

        // Skip if binding would fail creation
        if (binding == ClaimBinding.Bound) {
            vm.assume(_creditor == _debtor); // Only debtor can create bound claims
        }

        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Mark as paid
        vm.expectEmit(true, true, false, true);
        emit ClaimMarkedAsPaid(claimId);

        vm.prank(_creditor);
        bullaClaim.markClaimAsPaid(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be marked as paid");
    }

    /*///////////////////////////////////////////////////////////////
                        MULTI-CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function testMarkMultipleClaims() public {
        // Create multiple claims
        uint256 claimId1 = _newClaim(creditor, creditor, debtor);
        uint256 claimId2 = _newClaim(creditor, creditor, debtor);
        uint256 claimId3 = _newClaim(creditor, creditor, debtor);

        // Partially pay second claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId2, 0.5 ether);
        vm.stopPrank();

        // Mark first claim as paid
        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId1);

        // Mark second claim as paid (the one with partial payment)
        vm.prank(creditor);
        bullaClaim.markClaimAsPaid(claimId2);

        // Leave third claim pending

        // Verify each claim's status
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        Claim memory claim3 = bullaClaim.getClaim(claimId3);

        assertEq(uint256(claim1.status), uint256(Status.Paid), "Claim 1 should be marked as paid");
        assertEq(uint256(claim2.status), uint256(Status.Paid), "Claim 2 should be marked as paid");
        assertEq(uint256(claim3.status), uint256(Status.Pending), "Claim 3 should remain pending");

        assertEq(claim2.paidAmount, 0.5 ether, "Claim 2 should retain payment amount");
    }
}
