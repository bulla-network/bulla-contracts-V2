// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";
import {MockController} from "contracts/mocks/MockController.sol";

/// @notice covers test cases for cancelClaim() and cancelClaimFrom()
contract TestCancelClaim is BullaClaimTestHelper {
    address public deployer = address(0xB0b);

    uint256 creditorPK = uint256(0x012345);
    uint256 debtorPK = uint256(0x09876);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    address controller = address(0x03);
    MockController mockController;

    function setUp() public {
        weth = new WETH();

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(deployer, LockState.Unlocked, 0, 0, 0, 0, deployer);
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();
        mockController = new MockController(address(bullaClaim));

        // Set up approval for mock controller to create many claims
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(mockController),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max, // Max approvals
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(mockController),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
    }

    event ClaimRejected(uint256 indexed claimId, address indexed from, string note);

    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    function _newClaim(ClaimBinding binding) internal returns (uint256 claimId, Claim memory claim) {
        claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withBinding(binding).build()
        );
        claim = bullaClaim.getClaim(claimId);
    }

    function _newControlledClaim(ClaimBinding binding) internal returns (uint256 claimId, Claim memory claim) {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withBinding(binding).build();

        mockController.setCurrentUser(creditor);
        claimId = mockController.createClaim(params);
        claim = bullaClaim.getClaim(claimId);
    }

    function _setLockState(LockState lockState) internal {
        vm.prank(deployer);
        bullaClaim.setLockState(lockState);
    }

    /// @notice SPEC._spendCancelClaimApproval.S1
    function testRejectsIfDebtor() public {
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        string memory note = "No thanks";

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);

        // test with controller - uncontrolled claim should revert
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        assertTrue(claimId == 1);

        // Test that cancelClaimFrom requires controlled claim
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

        // test with controlled claim - should work
        (claimId, claim) = _newControlledClaim(ClaimBinding.Unbound);
        assertTrue(claimId == 2);

        mockController.setCurrentUser(debtor);

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);
        mockController.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);
    }

    /// @notice SPEC._spendCancelClaimApproval.S1
    function testRescindsIfCreditor() public {
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        string memory note = "No thanks";

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);

        // test with controller - uncontrolled claim should revert
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        assertTrue(claimId == 1);

        // Test that cancelClaimFrom requires controlled claim
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(creditor, claimId, note);

        // test with controlled claim - should work
        (claimId, claim) = _newControlledClaim(ClaimBinding.Unbound);

        mockController.setCurrentUser(creditor);

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);
        mockController.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);
    }

    function testRevertsIfNeitherCreditorOrDebtor(uint256 callerPK) public {
        vm.assume(privateKeyValidity(callerPK) && callerPK != creditorPK && callerPK != debtorPK);
        address randomAddress = vm.addr(callerPK);

        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        string memory note = "No thanks";

        vm.prank(randomAddress);
        vm.expectRevert(BullaClaimValidationLib.NotCreditorOrDebtor.selector);
        bullaClaim.cancelClaim(claimId, note);

        // Test that cancelClaimFrom requires controlled claim for random address (uncontrolled claim)
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(randomAddress, claimId, note);

        // Test with controlled claim - should still fail for random address
        (claimId,) = _newControlledClaim(ClaimBinding.Unbound);

        mockController.setCurrentUser(randomAddress);
        vm.expectRevert(BullaClaimValidationLib.NotCreditorOrDebtor.selector);
        mockController.cancelClaim(claimId, note);
    }

    function testCannotCancelIfLocked() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _setLockState(LockState.Locked);

        vm.expectRevert(IBullaClaimV2.Locked.selector);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        vm.expectRevert(IBullaClaimV2.Locked.selector);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // Test that cancelClaimFrom also reverts when locked (first for uncontrolled claim)
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        vm.prank(controller);
        bullaClaim.cancelClaimFrom(debtor, claimId, "nah");

        // Test with controlled claim when locked
        _setLockState(LockState.Unlocked);
        (uint256 controlledClaimId,) = _newControlledClaim(ClaimBinding.Unbound);
        _setLockState(LockState.Locked);

        mockController.setCurrentUser(debtor);
        vm.expectRevert(IBullaClaimV2.Locked.selector);
        mockController.cancelClaim(controlledClaimId, "nah");
    }

    function testCanCancelIfPartiallyLocked() public {
        // creditor creates and debtor rejects
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _setLockState(LockState.NoNewClaims);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rejected);

        // creditor creates and rescinds
        _setLockState(LockState.Unlocked);

        vm.startPrank(creditor);
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _setLockState(LockState.NoNewClaims);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rescinded);
    }

    function testControllerCannotCancelUncontrolledClaim() public {
        // creditor creates uncontrolled claim
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // controller cannot cancel uncontrolled claim
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(debtor, claimId, "No thanks");
    }

    function testCanCancelWhenBindingPending() public {
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();
        string memory note = "No thanks";

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);

        // test with controller - uncontrolled claim should revert
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        // controller cannot cancel uncontrolled claim
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

        // test with controlled claim
        (claimId, claim) = _newControlledClaim(ClaimBinding.BindingPending);

        mockController.setCurrentUser(debtor);

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);
        mockController.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);

        vm.startPrank(creditor);
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);

        // test with controller - uncontrolled claim should revert
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        // controller cannot cancel uncontrolled claim
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(creditor, claimId, note);

        // test with controlled claim
        (claimId, claim) = _newControlledClaim(ClaimBinding.BindingPending);

        mockController.setCurrentUser(creditor);

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);
        mockController.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);
    }

    function testCannotCancelIfNotMinted() public {
        vm.prank(debtor);
        vm.expectRevert(IBullaClaimV2.NotMinted.selector);
        bullaClaim.cancelClaim(1, "Reject");
    }

    function testDebtorCannotCancelClaimIfBound() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        string memory note = "No thanks";

        vm.startPrank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);
        vm.expectRevert(BullaClaimValidationLib.ClaimBound.selector);
        bullaClaim.cancelClaim(claimId, note);
        vm.stopPrank();

        // test with controller - should revert with MustBeControlledClaim for uncontrolled claim
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.MustBeControlledClaim.selector));
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

        // test with controlled claim - should still fail because claim is bound
        (uint256 controlledClaimId,) = _newControlledClaim(ClaimBinding.Unbound);

        // bind the controlled claim
        mockController.setCurrentUser(debtor);
        mockController.updateBinding(controlledClaimId, ClaimBinding.Bound);

        mockController.setCurrentUser(debtor);
        vm.expectRevert(BullaClaimValidationLib.ClaimBound.selector);
        mockController.cancelClaim(controlledClaimId, note);
    }

    function testCreditorCanCancelClaimIfBound() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        string memory note = "you're free!";
        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, note);
    }

    function testCannotCancelIfClaimIsDelegatedAndCallerIsNotController() public {
        // allow the controller to create a claim for the creditor
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: controller,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: controller,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // create a delegated claim
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(controller);
        uint256 claimId = bullaClaim.createClaimFrom(creditor, params);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, debtor));
        bullaClaim.cancelClaim(claimId, "No thanks");
    }

    function testCanCallIfDelegatedAndCallerIsController() public {
        // allow the controller to create a claim for the creditor
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: controller,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: controller,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // create a delegated claim
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(controller);
        uint256 claimId = bullaClaim.createClaimFrom(creditor, params);

        // Controller can cancel the controlled claim
        vm.prank(controller);
        bullaClaim.cancelClaimFrom(creditor, claimId, "No thanks");
    }

    function testCannotCancelIfRepaying() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.deal(debtor, 10 ether);

        vm.startPrank(debtor);
        weth.deposit{value: 5 ether}();
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId, 0.5 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Repaying);

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        bullaClaim.cancelClaim(claimId, "No thanks");
        vm.stopPrank();
    }

    /// cover all cases of double rescinding / rejecting
    function testCannotCancelIfAlreadyCancelled() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // test double rescind
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "nah");

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test double reject
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        bullaClaim.cancelClaim(claimId, "nah");
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test reject then rescind
        vm.startPrank(debtor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        bullaClaim.cancelClaim(claimId, "nah");
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test rescind then reject
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        bullaClaim.cancelClaim(claimId, "nah");
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");
    }

    function testCannotCancelIfPaid() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.deal(debtor, 10 ether);

        vm.startPrank(debtor);
        weth.deposit{value: 5 ether}();
        weth.approve(address(bullaClaim), 1 ether);
        bullaClaim.payClaim(claimId, 1 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Paid);

        vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
        bullaClaim.cancelClaim(claimId, "No thanks");
        vm.stopPrank();
    }
}
