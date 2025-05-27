// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

/// @notice covers test cases for updateBinding() and updateBindingFrom()
/// @notice SPEC: updateBinding() TODO
/// @notice SPEC: _spendUpdateBindingApproval()
///     A function can call this function to verify and "spend" `from`'s approval of `operator` to update a claim's binding given:
///         S1. `operator` has > 0 approvalCount from `from` address -> otherwise: reverts
///
///     RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
contract TestUpdateBinding is BullaClaimTestHelper {
    uint256 creditorPK = uint256(0x012345);
    uint256 debtorPK = uint256(0x09876);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    address operator = address(0x03);

    function setUp() public {
        weth = new WETH();

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        bullaClaim = (new Deployer()).deploy_test(address(0xB0b), LockState.Unlocked);
        sigHelper = new EIP712Helper(address(bullaClaim));
    }

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

    function _newClaim(ClaimBinding binding) internal returns (uint256 claimId, Claim memory claim) {
        claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withBinding(binding)
                .build()
        );
        claim = bullaClaim.getClaim(claimId);
    }

    /// @notice SPEC._spendUpdateBindingApproval.S1
    function testDebtorBindsSelfToClaim() public {
        // test case: unbound invoice
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.prank(debtor);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.Bound);

        // debtor commits to paying
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.Bound);

        // test with operator
        vm.startPrank(creditor);

        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        assertTrue(claimId == 2 && claim.binding == ClaimBinding.Unbound);

        // permit an operator
        _permitUpdateBinding({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.Bound);

        // debtor commits to paying
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);
        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.Bound);
    }

    /// @notice SPEC._spendUpdateBindingApproval.S1
    function testDebtorUpdatesToBindingPending() public {
        // test case: strange, but debtor can update to pending
        vm.startPrank(creditor);
        (uint256 claimId, Claim memory claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.prank(debtor);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.BindingPending);

        // debtor commits to paying
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);

        claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.BindingPending);

        // test with operator
        vm.startPrank(creditor);

        // make a new claim
        (claimId, claim) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        assertTrue(claimId == 2 && claim.binding == ClaimBinding.BindingPending);

        // permit an operator
        _permitUpdateBinding({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

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
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.startPrank(debtor);
        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, debtor, ClaimBinding.Bound);

        // debtor commits to paying
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // in the case of trying to set the claim to unbound
        vm.expectRevert(BullaClaim.ClaimBound.selector);
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        // in the case of trying to set the claim to binding pending
        vm.expectRevert(BullaClaim.ClaimBound.selector);
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);
        vm.stopPrank();

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Bound);

        // test with operator
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // permit an operator
        _permitUpdateBinding({_userPK: debtorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // an operator cannot unbind a debtor
        vm.startPrank(operator);
        vm.expectRevert(BullaClaim.ClaimBound.selector);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Unbound);

        vm.expectRevert(BullaClaim.ClaimBound.selector);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.BindingPending);
    }

    function testCreditorCanUpdateToBindingPending() public {
        // test case: creditor wants a debtor to commit to a claim
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        // Creditor wants to notify the debtor
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);

        // test with an operator
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        // permit an operator
        _permitUpdateBinding({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        vm.startPrank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);
    }

    function testCannotUpdateBindingIfNotMinted() public {
        vm.prank(debtor);
        vm.expectRevert(BullaClaim.NotMinted.selector);
        bullaClaim.updateBinding(1, ClaimBinding.Unbound);
    }

    function testCannotUpdateBindingNotPending(uint8 _claimStatus) public {
        Status claimStatus = Status(_claimStatus % 4);
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.deal(debtor, 1 ether);
        vm.startPrank(debtor);
        weth.deposit{value: 1 ether}();
        weth.approve(address(bullaClaim), 1 ether);
        vm.stopPrank();

        if (claimStatus == Status.Paid) {
            vm.prank(debtor);
            bullaClaim.payClaim(claimId, 1 ether);
        } else if (claimStatus == Status.Repaying) {
            vm.prank(debtor);
            bullaClaim.payClaim(claimId, 0.5 ether);
        } else if (claimStatus == Status.Rescinded) {
            vm.prank(creditor);
            bullaClaim.cancelClaim(claimId, "rescind");
        } else if (claimStatus == Status.Rejected) {
            vm.prank(debtor);
            bullaClaim.cancelClaim(claimId, "reject");
        }

        if (claimStatus != Status.Repaying && claimStatus != Status.Pending) {
            vm.expectRevert(BullaClaim.ClaimNotPending.selector);
        }
        vm.prank(debtor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);
    }

    function testCreditorCanUpdateToUnbound() public {
        // test case: creditor can "free" a debtor from a claim
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

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
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        _permitUpdateBinding({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

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
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        // creditor tries to bind
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // try the above, but for a binding pending claim
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // also test for operators
        _permitUpdateBinding({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        // creditor tries to bind
        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Bound);

        // try the above, but for a binding pending claim
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Bound);
    }

    function testNonCreditorOrDebtorCannotUpdateAnything(address caller, uint8 _newBinding) public {
        vm.assume(caller != creditor && caller != debtor);

        ClaimBinding newBinding = ClaimBinding(_newBinding % 3);

        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectRevert(BullaClaim.NotCreditorOrDebtor.selector);

        vm.prank(caller);
        bullaClaim.updateBinding(claimId, newBinding);
    }

    function testCannotUpdateIfDelegated() public {
        // test case: a creditor or a debtor cannot update a claim's binding if it's delegated
        address controllerAddress = address(0xDEADCAFE);
        _permitCreateClaim(creditorPK, controllerAddress, 1, CreateClaimApprovalType.Approved, false);

        vm.startPrank(controllerAddress);
        uint256 claimId = bullaClaim.createClaimFrom(
            creditor,
            new CreateClaimParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withBinding(ClaimBinding.BindingPending)
                .build()
        );
        vm.stopPrank();

        // creditor can't update the binding directly
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, creditor));
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        // neither can the debtor
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor));
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // the controller must be approved
        _permitUpdateBinding({_userPK: debtorPK, _operator: controllerAddress, _approvalCount: type(uint64).max});
        vm.prank(controllerAddress);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);
    }

    /// @notice SPEC._spendUpdateBindingApproval.RES1
    function testUpdateBindingFromDecrementsApprovals() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();
        _permitUpdateBinding({_userPK: creditorPK, _operator: operator, _approvalCount: 12});

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        (,, UpdateBindingApproval memory approval,,) = bullaClaim.approvals(creditor, operator);

        assertEq(approval.approvalCount, 11, "Should have 11 approvals");

        // doesn't decrement if approvalCount is uint64.max
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _permitUpdateBinding({_userPK: creditorPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        (,, approval,,) = bullaClaim.approvals(creditor, operator);

        assertEq(approval.approvalCount, type(uint64).max);
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.binding), uint256(ClaimBinding.BindingPending), "Binding should be updated");
    }

    /// @notice SPEC._spendUpdateBindingApproval.S1
    function testCannotUpdateBindingFromIfUnauthorized() public {
        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        _permitUpdateBinding({_userPK: creditorPK, _operator: operator, _approvalCount: 1});

        vm.prank(operator);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        (,, UpdateBindingApproval memory approval,,) = bullaClaim.approvals(creditor, operator);

        assertEq(approval.approvalCount, 0, "Should have 0 approvals");

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);
    }
}
