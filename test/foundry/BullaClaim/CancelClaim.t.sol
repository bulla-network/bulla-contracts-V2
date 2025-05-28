// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

/// @notice covers test cases for cancelClaim() and cancelClaimFrom()
/// @notice SPEC: canceClaim() TODO
/// @notice SPEC: _spendCancelClaimApproval()
///     A function can call this internal function to verify and "spend" `from`'s approval of `operator` to cancel a claim given:
///         S1. `operator` has > 0 approvalCount from `from` address -> otherwise: reverts
///
///     RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
contract TestCancelClaim is BullaClaimTestHelper {
    address public deployer = address(0xB0b);

    uint256 creditorPK = uint256(0x012345);
    uint256 debtorPK = uint256(0x09876);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    address operator = address(0x03);

    function setUp() public {
        weth = new WETH();

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        bullaClaim = (new Deployer()).deploy_test(deployer, LockState.Unlocked);
        sigHelper = new EIP712Helper(address(bullaClaim));
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

        // test with operator
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        assertTrue(claimId == 2);

        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

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

        // test with operator
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        assertTrue(claimId == 2);

        // permit an operator
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, note);

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
        vm.expectRevert(BullaClaim.NotCreditorOrDebtor.selector);
        bullaClaim.cancelClaim(claimId, note);

        // test with operator
        _permitCancelClaim({_userPK: callerPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotCreditorOrDebtor.selector);
        bullaClaim.cancelClaimFrom(randomAddress, claimId, note);
    }

    function testCannotCancelIfLocked() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _setLockState(LockState.Locked);

        vm.expectRevert(BullaClaim.Locked.selector);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        vm.expectRevert(BullaClaim.Locked.selector);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test with operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectRevert(BullaClaim.Locked.selector);
        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, "nah");

        vm.expectRevert(BullaClaim.Locked.selector);
        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, "nah");
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

    function testOperatorCanCancelIfPartiallyLocked() public {
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        // creditor creates and operator rejects for debtor
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _setLockState(LockState.NoNewClaims);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, "No thanks");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rejected);

        // creditor creates and operator rejects for creditor
        _setLockState(LockState.Unlocked);

        vm.startPrank(creditor);
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _setLockState(LockState.NoNewClaims);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, "nah");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rescinded);
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

        // test with operator
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();
        assertTrue(claimId == 2);

        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

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

        // test with operator
        vm.startPrank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();
        assertTrue(claimId == 4);

        // permit an operator
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);
    }

    function testCannotCancelIfNotMinted() public {
        vm.prank(debtor);
        vm.expectRevert(BullaClaim.NotMinted.selector);
        bullaClaim.cancelClaim(1, "Reject");
    }

    function testDebtorCannotCancelClaimIfBound() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        string memory note = "No thanks";

        vm.startPrank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);
        vm.expectRevert(BullaClaim.ClaimBound.selector);
        bullaClaim.cancelClaim(claimId, note);
        vm.stopPrank();

        // test with operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectRevert(BullaClaim.ClaimBound.selector);
        bullaClaim.cancelClaimFrom(debtor, claimId, note);
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
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: operator,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: operator,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // create a delegated claim
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(operator);
        uint256 claimId = bullaClaim.createClaimFrom(creditor, params);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor));
        bullaClaim.cancelClaim(claimId, "No thanks");
    }

    function testCanCallIfDelegatedAndCallerIsController() public {
        // allow the controller to create a claim for the creditor
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: operator,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: operator,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // create a delegated claim
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(operator);
        uint256 claimId = bullaClaim.createClaimFrom(creditor, params);

        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
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

        vm.expectRevert(BullaClaim.ClaimNotPending.selector);
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

        vm.expectRevert(BullaClaim.ClaimNotPending.selector);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test double reject
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        bullaClaim.cancelClaim(claimId, "nah");
        vm.stopPrank();

        vm.expectRevert(BullaClaim.ClaimNotPending.selector);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test reject then rescind
        vm.startPrank(debtor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        bullaClaim.cancelClaim(claimId, "nah");
        vm.stopPrank();

        vm.expectRevert(BullaClaim.ClaimNotPending.selector);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test rescind then reject
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        bullaClaim.cancelClaim(claimId, "nah");
        vm.stopPrank();

        vm.expectRevert(BullaClaim.ClaimNotPending.selector);
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

        vm.expectRevert(BullaClaim.ClaimNotPending.selector);
        bullaClaim.cancelClaim(claimId, "No thanks");
        vm.stopPrank();
    }

    /// @notice SPEC._spendCancelClaimApproval.RES1
    function testCancelClaimFromDecrements(uint64 approvalCount) public {
        string memory note = "Nope";
        vm.assume(approvalCount > 0 && approvalCount < type(uint64).max);

        // test for reject

        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: approvalCount});

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

        (,,, CancelClaimApproval memory approval,) = bullaClaim.approvals(debtor, operator);
        assertEq(approval.approvalCount, approvalCount - 1);

        // test for rescind

        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // permit an operator
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: approvalCount});

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, note);

        (,,, approval,) = bullaClaim.approvals(creditor, operator);
        assertEq(approval.approvalCount, approvalCount - 1);
    }

    /// @notice SPEC._spendCancelClaimApproval.S1
    function testCancelClaimFromRevertsIfUnapproved() public {
        // make a new claim
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: 5});

        // revokes approval
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: 0});

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        bullaClaim.cancelClaimFrom(debtor, claimId, "Nope");
    }

    /// @notice SPEC._spendCancelClaimApproval.RES1
    function testCancelClaimFromDoesNotDecrementIfApprovalMaxedOut() public {
        // make a new claim
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, "Nope");

        (,,, CancelClaimApproval memory approval,) = bullaClaim.approvals(debtor, operator);
        assertEq(approval.approvalCount, type(uint64).max);
    }
}
