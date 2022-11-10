// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestCancelClaim is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
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

        (bullaClaim,) = (new Deployer()).deploy_test(deployer, address(0xfee), LockState.Unlocked, 0);
        sigHelper = new EIP712Helper(address(bullaClaim));
    }

    event ClaimRejected(uint256 indexed claimId, address indexed from, string note);

    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    function _newClaim(ClaimBinding binding) internal returns (uint256 claimId, Claim memory claim) {
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Creditor,
                binding: binding
            })
        );
        claim = bullaClaim.getClaim(claimId);
    }

    function _permitCancelClaim(uint256 _userPK, address _operator, uint64 _approvalCount) internal {
        Signature memory sig = sigHelper.signCancelClaimPermit(_userPK, vm.addr(_userPK), _operator, _approvalCount);
        bullaClaim.permitCancelClaim(vm.addr(_userPK), _operator, _approvalCount, sig);
    }

    function _setLockState(LockState lockState) internal {
        vm.prank(deployer);
        bullaClaim.setLockState(lockState);
    }

    function testRejectsIfDebtor() public {
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        string memory note = "No thanks";

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);

        // test with operator
        vm.prank(creditor);

        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
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

    function testRescindsIfCreditor() public {
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        string memory note = "No thanks";

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);

        // test with operator
        vm.prank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
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

        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        string memory note = "No thanks";

        vm.prank(randomAddress);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotCreditorOrDebtor.selector, randomAddress));
        bullaClaim.cancelClaim(claimId, note);

        // test with operator
        _permitCancelClaim({_userPK: callerPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotCreditorOrDebtor.selector, randomAddress));
        bullaClaim.cancelClaimFrom(randomAddress, claimId, note);
    }

    function testCannotCancelIfLocked() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

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
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);

        _setLockState(LockState.NoNewClaims);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rejected);

        // creditor creates and rescinds
        _setLockState(LockState.Unlocked);

        vm.prank(creditor);
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);

        _setLockState(LockState.NoNewClaims);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rescinded);
    }

    function testOperatorCanCancelIfPartiallyLocked() public {
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        // creditor creates and operator rejects for debtor
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);

        _setLockState(LockState.NoNewClaims);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, "No thanks");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rejected);

        // creditor creates and operator rejects for creditor
        _setLockState(LockState.Unlocked);

        vm.prank(creditor);
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);

        _setLockState(LockState.NoNewClaims);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, "nah");

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Rescinded);
    }

    function testCanCancelWhenBindingPending() public {
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.BindingPending);
        string memory note = "No thanks";

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);

        // test with operator
        vm.prank(creditor);

        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        assertTrue(claimId == 2);

        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rejected);
        vm.prank(creditor);
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, note);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.status == Status.Rescinded);

        // test with operator
        vm.prank(creditor);
        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
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
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotMinted.selector, 1));
        bullaClaim.cancelClaim(1, "Reject");
    }

    function testDebtorCannotCancelClaimIfBound() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        string memory note = "No thanks";

        vm.startPrank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimBound.selector, claimId));
        bullaClaim.cancelClaim(claimId, note);
        vm.stopPrank();

        // test with operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimBound.selector, claimId));
        bullaClaim.cancelClaimFrom(debtor, claimId, note);
    }

    function testCreditorCanCancelClaimIfBound() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        string memory note = "you're free!";
        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, note);
    }

    function testCannotCancelIfClaimIsDelegatedAndCallerIsNotDelegator() public {
        // allow the delegator to create a claim for the creditor
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
        vm.prank(operator);
        uint256 claimId = bullaClaim.createClaimFrom(
            creditor,
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: operator, // operator is the delegator
                feePayer: FeePayer.Creditor,
                binding: ClaimBinding.Unbound
            })
        );

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimDelegated.selector, 1, operator));
        bullaClaim.cancelClaim(claimId, "No thanks");
    }

    function testCanCallIfDelegatedAndCallerIsDelegator() public {
        // allow the delegator to create a claim for the creditor
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
        vm.prank(operator);
        uint256 claimId = bullaClaim.createClaimFrom(
            creditor,
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: operator, // operator is the delegator
                feePayer: FeePayer.Creditor,
                binding: ClaimBinding.Unbound
            })
        );

        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, "No thanks");
    }

    function testCannotCancelIfRepaying() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.deal(debtor, 10 ether);

        vm.startPrank(debtor);
        weth.deposit{value: 5 ether}();
        weth.approve(address(bullaClaim), 0.5 ether);
        bullaClaim.payClaim(claimId, 0.5 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Repaying);

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimNotPending.selector, claimId));
        bullaClaim.cancelClaim(claimId, "No thanks");
        vm.stopPrank();
    }

    /// cover all cases of double rescinding / rejecting
    function testCannotCancelIfAlreadyCancelled() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        // test double rescind
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "nah");

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimNotPending.selector, claimId));
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test double reject
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "nah");

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimNotPending.selector, claimId));
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test reject then rescind
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "nah");

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimNotPending.selector, claimId));
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "No thanks");

        // test rescind then reject
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.prank(creditor);
        bullaClaim.cancelClaim(claimId, "nah");

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimNotPending.selector, claimId));
        vm.prank(debtor);
        bullaClaim.cancelClaim(claimId, "No thanks");
    }

    function testCannotCancelIfPaid() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.deal(debtor, 10 ether);

        vm.startPrank(debtor);
        weth.deposit{value: 5 ether}();
        weth.approve(address(bullaClaim), 1 ether);
        bullaClaim.payClaim(claimId, 1 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Paid);

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.ClaimNotPending.selector, claimId));
        bullaClaim.cancelClaim(claimId, "No thanks");
        vm.stopPrank();
    }

    function testCancelClaimFromDecrements(uint64 approvalCount) public {
        string memory note = "Nope";
        vm.assume(approvalCount > 0 && approvalCount < type(uint64).max);

        // test for reject

        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: approvalCount});

        vm.expectEmit(true, true, true, true);
        emit ClaimRejected(claimId, debtor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, note);

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(debtor, operator);
        assertEq(approval.approvalCount, approvalCount - 1);

        // test for rescind

        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        // permit an operator
        _permitCancelClaim({_userPK: creditorPK, _operator: operator, _approvalCount: approvalCount});

        vm.expectEmit(true, true, true, true);
        emit ClaimRescinded(claimId, creditor, note);

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(creditor, claimId, note);

        (,,, approval) = bullaClaim.approvals(creditor, operator);
        assertEq(approval.approvalCount, approvalCount - 1);
    }

    function testCancelClaimFromRevertsIfUnapproved() public {
        // make a new claim
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: 5});

        // revokes approval
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: 0});

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        bullaClaim.cancelClaimFrom(debtor, claimId, "Nope");
    }

    function testCancelClaimFromDoesNotDecrementIfApprovalMaxedOut() public {
        // make a new claim
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        // permit an operator
        _permitCancelClaim({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        bullaClaim.cancelClaimFrom(debtor, claimId, "Nope");

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(debtor, operator);
        assertEq(approval.approvalCount, type(uint64).max);
    }
}