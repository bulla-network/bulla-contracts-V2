// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";

/// @notice covers test cases for updateBinding() and updateBindingFrom()
/// @notice SPEC: updateBinding() TODO
/// @notice SPEC: updateBindingFrom() TODO
contract TestUpdateBinding is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;

    uint256 creditorPK = uint256(0x012345);
    uint256 debtorPK = uint256(0x09876);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    address operator = address(0x03);

    function setUp() public {
        weth = new WETH();

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        (bullaClaim,) = (new Deployer()).deploy_test(address(0xB0b), address(0xfee), LockState.Unlocked, 0);
        sigHelper = new EIP712Helper(address(bullaClaim));
    }

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

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

    function _permitUpdateBinding(uint256 _ownerPK, address _operator, uint64 _approvalCount) internal {
        Signature memory sig = sigHelper.signUpdateBindingPermit(_ownerPK, vm.addr(_ownerPK), _operator, _approvalCount);
        bullaClaim.permitUpdateBinding(vm.addr(_ownerPK), _operator, _approvalCount, sig);
    }

    function testDebtorBindsSelfToClaim() public {
        // test case: unbound invoice
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);

        vm.prank(debtor);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.Bound);

        // debtor commits to paying
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.Bound);

        // test with operator
        vm.prank(creditor);

        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        assertTrue(claimId == 2 && claim.binding == ClaimBinding.Unbound);

        // permit an operator
        _permitUpdateBinding({_ownerPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.Bound);

        // debtor commits to paying
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);
        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.Bound);
    }

    function testDebtorUpdatesToBindingPending() public {
        // test case: strange, but debtor can update to pending
        vm.prank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.BindingPending);

        vm.prank(debtor);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.BindingPending);

        // debtor commits to paying
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.BindingPending);

        // test with operator
        vm.prank(creditor);

        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        assertTrue(claimId == 2 && claim.binding == ClaimBinding.BindingPending);

        // permit an operator
        _permitUpdateBinding({_ownerPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.BindingPending);

        // debtor commits to paying
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.BindingPending);
        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.BindingPending);
    }

    function testDebtorCannotUnbindIfBound() public {
        // test case: debtor agrees to an invoice, but tries to back out
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.startPrank(debtor);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.Bound);

        // debtor commits to paying
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // in the case of trying to set the claim to unbound
        vm.expectRevert(abi.encodeWithSignature("ClaimBound(uint256)", claimId));
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        // in the case of trying to set the claim to binding pending
        vm.expectRevert(abi.encodeWithSignature("ClaimBound(uint256)", claimId));
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);
        vm.stopPrank();

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Bound);

        // test with operator
        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        // permit an operator
        _permitUpdateBinding({_ownerPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // an operator cannot unbind a debtor
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSignature("ClaimBound(uint256)", claimId));
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Unbound);

        vm.expectRevert(abi.encodeWithSignature("ClaimBound(uint256)", claimId));
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.BindingPending);
    }

    function testCreditorCanUpdateToBindingPending() public {
        // test case: creditor wants a debtor to commit to a claim
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        // Creditor wants to notify the debtor
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);

        // test with an operator
        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        // permit an operator
        _permitUpdateBinding({_ownerPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        vm.startPrank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);
    }

    function testCreditorCanUpdateToUnbound() public {
        // test case: creditor can "free" a debtor from a claim
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);

        // debtor accepts
        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.Unbound);

        // creditor frees debtor
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Unbound);

        // (also test bound -> bindingPending)

        // debtor reaccepts
        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        // the creditor can move the binding back to pending
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);
    }

    function testOperatorCanUpdateToUnboundForCreditor() public {
        // test case: creditor can "free" a debtor from a claim
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);

        _permitUpdateBinding({_ownerPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        // debtor accepts
        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.Unbound);

        // creditor frees debtor
        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Unbound);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Unbound);

        // (also test bound -> bindingPending)

        // debtor reaccepts
        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        // the creditor can move the binding back to pending
        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);
    }

    function testCreditorCannotUpdateToBound() public {
        uint256 claimId;
        // test case: a malicous creditor tries to directly bind a debtor after claim creation
        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        // creditor tries to bind
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // try the above, but for a binding pending claim
        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.BindingPending);

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // also test for operators
        _permitUpdateBinding({_ownerPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        // creditor tries to bind
        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Bound);

        // try the above, but for a binding pending claim
        vm.prank(creditor);
        (claimId,) = _newClaim(ClaimBinding.BindingPending);

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Bound);
    }

    function testNonCreditorOrDebtorCannotUpdateAnything(address caller, uint8 _newBinding) public {
        vm.assume(caller != creditor && caller != debtor);

        ClaimBinding newBinding = ClaimBinding(_newBinding % 3);

        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);

        vm.expectRevert(abi.encodeWithSignature("NotCreditorOrDebtor(address)", caller));

        vm.prank(caller);
        bullaClaim.updateBinding(claimId, newBinding);
    }

    function testCannotUpdateIfDelegated() public {
        // test case: a creditor or a debtor cannot update a claim's binding if it's delegated
        address delegatorAddress = address(0xDEADCAFE);

        vm.prank(delegatorAddress);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: delegatorAddress,
                feePayer: FeePayer.Creditor,
                binding: ClaimBinding.BindingPending
            })
        );

        // creditor can't update the binding directly
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSignature("ClaimDelegated(uint256,address)", claimId, delegatorAddress));
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        // neither can the debtor
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSignature("ClaimDelegated(uint256,address)", claimId, delegatorAddress));
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // the delegator must be approved
        _permitUpdateBinding({_ownerPK: debtorPK, _operator: delegatorAddress, _approvalCount: type(uint64).max});
        vm.prank(delegatorAddress);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);
    }

    function testUpdateBindingFromDecrementsApprovals() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        _permitUpdateBinding({_ownerPK: creditorPK, _operator: operator, _approvalCount: 12});

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        (,, UpdateBindingApproval memory approval,) = bullaClaim.approvals(creditor, operator);

        assertEq(approval.approvalCount, 11);

        // doesn't decrement if approvalCount is uint64.max

        (claimId,) = _newClaim(ClaimBinding.Unbound);
        _permitUpdateBinding({_ownerPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        (,, approval,) = bullaClaim.approvals(creditor, operator);

        assertEq(approval.approvalCount, type(uint64).max);
    }

    function testCannotUpdateBindingFromIfUnauthorized() public {
        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);

        _permitUpdateBinding({_ownerPK: creditorPK, _operator: operator, _approvalCount: 1});

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        (,, UpdateBindingApproval memory approval,) = bullaClaim.approvals(creditor, operator);

        assertEq(approval.approvalCount, 0);

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);
    }
}
