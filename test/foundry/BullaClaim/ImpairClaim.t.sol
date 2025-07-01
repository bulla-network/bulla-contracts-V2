// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Claim, Status, ClaimBinding, CreateClaimParams, ClaimMetadata, LockState} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {IBullaClaim} from "contracts/interfaces/IBullaClaim.sol";

contract TestImpairClaim is BullaClaimTestHelper {
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 randomPK = uint256(0x03);
    uint256 controllerPK = uint256(0x04);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address randomUser = vm.addr(randomPK);
    address controller = vm.addr(controllerPK);

    event ClaimImpaired(uint256 indexed claimId);

    function setUp() public {
        weth = new WETH();
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });
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
    }

    /*///////////////////////////////////////////////////////////////
                            HAPPY PATH TESTS
    //////////////////////////////////////////////////////////////*/

    function testImpairClaim_Success() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Claim should be impaired");
    }

    function testImpairClaim_FromRepaying() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Make partial payment to put claim in repaying status
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId, 0.5 ether);
        vm.stopPrank();

        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimBefore.status), uint256(Status.Repaying), "Claim should be repaying");

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Impaired), "Claim should be impaired");
    }

    function testImpairClaimFrom_WithController() public {
        PenalizedClaim penalizedClaim = new PenalizedClaim(address(bullaClaim));

        // Setup approval for penalizedClaim to create claims
        _permitCreateClaim(creditorPK, address(penalizedClaim), 1);

        vm.startPrank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).withDueBy(
                block.timestamp + 30 days
            ).build()
        );
        vm.stopPrank();

        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(claimBefore.controller, address(penalizedClaim), "Controller should be set");

        vm.warp(block.timestamp + 38 days);

        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(address(penalizedClaim));
        bullaClaim.impairClaimFrom(creditor, claimId);

        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Impaired), "Claim should be impaired");
    }

    /*///////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotImpairClaim_NotCreditor() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Debtor cannot impair
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaClaim.impairClaim(claimId);

        // Random user cannot impair
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_WrongController() public {
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
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, creditor));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaimFrom_NotApproved() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.MustBeControlledClaim.selector));
        bullaClaim.impairClaimFrom(creditor, claimId);
    }

    /*///////////////////////////////////////////////////////////////
                        STATE VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotImpairClaim_WrongStatus() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Fully pay the claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 1 ether);
        bullaClaim.payClaim(claimId, 1 ether);
        vm.stopPrank();

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be paid");

        // Cannot impair paid claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_RejectedClaim() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Reject the claim
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "Rejected by debtor");

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Rejected), "Claim should be rejected");

        // Cannot impair rejected claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_RescindedClaim() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Rescind the claim
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "Rescinded by creditor");

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Rescinded), "Claim should be rescinded");

        // Cannot impair rescinded claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_AlreadyImpaired() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Impair the claim first time
        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Claim should be impaired");

        // Cannot impair already impaired claim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_ContractLocked() public {
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        // Lock the contract
        bullaClaim.setLockState(LockState.Locked);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.Locked.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_NotMinted() public {
        uint256 nonExistentClaimId = 999;

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotMinted.selector));
        bullaClaim.impairClaim(nonExistentClaimId);
    }

    /*///////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testPayImpairedClaim_Success() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Impair the claim
        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        // Should still be able to pay impaired claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId, 0.5 ether);
        vm.stopPrank();

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Repaying), "Claim should be repaying");
        assertEq(claim.paidAmount, 0.5 ether, "Paid amount should be recorded");
    }

    function testPayImpairedClaim_FullPayment() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Impair the claim
        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        // Fully pay impaired claim
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 1 ether);
        bullaClaim.payClaim(claimId, 1 ether);
        vm.stopPrank();

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Paid), "Claim should be paid");
        assertEq(claim.paidAmount, 1 ether, "Full amount should be paid");
    }

    function testUpdateBindingImpairedClaim_Success() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Impair the claim
        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        // Should still be able to update binding on impaired claim
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.binding), uint256(ClaimBinding.BindingPending), "Binding should be updated");
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Status should remain impaired");
    }

    /*///////////////////////////////////////////////////////////////
                            EVENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testImpairClaim_EventEmission() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);
    }

    function testImpairClaimFrom_EventEmission() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        _permitCreateClaim(creditorPK, controller, 1);

        vm.prank(controller);
        uint256 claimId = bullaClaim.createClaimFrom(creditor, params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(controller);
        bullaClaim.impairClaimFrom(creditor, claimId);
    }

    /*///////////////////////////////////////////////////////////////
                        NFT TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function testImpairClaim_AfterNFTTransfer() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Transfer NFT to another address
        vm.prank(creditor);
        bullaClaim.transferFrom(creditor, randomUser, claimId);

        assertEq(bullaClaim.ownerOf(claimId), randomUser, "NFT should be transferred");

        // New owner should be able to impair
        vm.prank(randomUser);
        bullaClaim.impairClaim(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Claim should be impaired");

        // Move back to start
        vm.warp(block.timestamp - 38 days);

        // Original creditor should not be able to impair
        vm.prank(creditor);
        uint256 claimId2 = bullaClaim.createClaim(params);

        // Move past due date + grace period for second claim
        vm.warp(block.timestamp + 38 days);

        vm.prank(creditor);
        bullaClaim.transferFrom(creditor, randomUser, claimId2);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaClaim.impairClaim(claimId2);
    }

    /*///////////////////////////////////////////////////////////////
                        EDGE CASES AND FUZZING
    //////////////////////////////////////////////////////////////*/

    function testImpairClaim_EdgeCases() public {
        // Test with maximum uint128 amount
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(uint256(type(uint128).max)).withToken(address(weth)).withDueBy(block.timestamp + 30 days).build(
        );

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Large claim should be impaired");
    }

    function test_FUZZ_impairClaim(uint256 pk, address _debtor, uint128 claimAmount, address token, uint8 bindingType)
        public
    {
        vm.assume(privateKeyValidity(pk));
        vm.assume(claimAmount > 0);
        vm.assume(bindingType <= 2); // Valid binding types

        address _creditor = vm.addr(pk);
        ClaimBinding binding = ClaimBinding(bindingType);

        // Create claim with fuzzed parameters
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor)
            .withClaimAmount(claimAmount).withToken(token).withBinding(binding).withDueBy(block.timestamp + 30 days).build();

        // Skip if binding would fail creation
        if (binding == ClaimBinding.Bound) {
            vm.assume(_creditor == _debtor); // Only debtor can create bound claims
        }

        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Impair the claim
        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(_creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Claim should be impaired");
    }

    /*///////////////////////////////////////////////////////////////
                        MULTI-CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function testImpairMultipleClaims() public {
        // Create claims with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId1 = bullaClaim.createClaim(params);
        vm.prank(creditor);
        uint256 claimId2 = bullaClaim.createClaim(params);
        vm.prank(creditor);
        uint256 claimId3 = bullaClaim.createClaim(params);

        // Move past due date + grace period
        vm.warp(block.timestamp + 38 days);

        // Impair first claim
        vm.prank(creditor);
        bullaClaim.impairClaim(claimId1);

        // Partially pay second claim, then impair
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId2, 0.5 ether);
        vm.stopPrank();

        vm.prank(creditor);
        bullaClaim.impairClaim(claimId2);

        // Leave third claim pending

        // Verify each claim's status
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        Claim memory claim3 = bullaClaim.getClaim(claimId3);

        assertEq(uint256(claim1.status), uint256(Status.Impaired), "Claim 1 should be impaired");
        assertEq(uint256(claim2.status), uint256(Status.Impaired), "Claim 2 should be impaired");
        assertEq(uint256(claim3.status), uint256(Status.Pending), "Claim 3 should remain pending");

        assertEq(claim2.paidAmount, 0.5 ether, "Claim 2 should retain payment amount");
    }

    function testCannotImpairClaim_StillInGracePeriod() public {
        // Create claim with due date and grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date but still within grace period
        vm.warp(block.timestamp + 35 days);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.StillInGracePeriod.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testCannotImpairClaim_NoDueBy() public {
        // Create claim without due date
        uint256 claimId = _newClaim(creditor, creditor, debtor);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NoDueBy.selector));
        bullaClaim.impairClaim(claimId);
    }

    function testImpairClaim_WithZeroGracePeriod() public {
        // Create claim with due date but no grace period
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDueBy(block.timestamp + 30 days).withImpairmentGracePeriod(0).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Move past due date (no grace period to wait for)
        vm.warp(block.timestamp + 31 days);

        vm.expectEmit(true, true, false, true);
        emit ClaimImpaired(claimId);

        vm.prank(creditor);
        bullaClaim.impairClaim(claimId);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Impaired), "Claim should be impaired");
    }
}
