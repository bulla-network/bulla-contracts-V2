// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";

/// @notice covers test cases for updateBinding() and updateBindingFrom()
/// @notice SPEC: updateBinding() TODO
/// @notice SPEC: _spendUpdateBindingApproval()
///     A function can call this function to verify and "spend" `from`'s approval of `controller` to update a claim's binding given:
///         S1. `controller` has > 0 approvalCount from `from` address -> otherwise: reverts
///
///     RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
contract TestUpdateBinding is BullaClaimTestHelper {
    uint256 creditorPK = uint256(0x012345);
    uint256 debtorPK = uint256(0x09876);

    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    address controller = address(0x03);

    function setUp() public {
        weth = new WETH();

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(0xB0b), LockState.Unlocked, 0, 0, 0, address(0xB0b));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        _permitCreateClaim(creditorPK, controller, 2);
    }

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

    function _newClaim(ClaimBinding binding) internal returns (uint256 claimId, Claim memory claim) {
        claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withBinding(binding).build()
        );
        claim = bullaClaim.getClaim(claimId);
    }

    function _newClaimFrom(address from, ClaimBinding binding) internal returns (uint256 claimId, Claim memory claim) {
        claimId = bullaClaim.createClaimFrom(
            from,
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withBinding(binding).build()
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

        // test with controller
        vm.startPrank(controller);
        // make a new claim
        (claimId, claim) = _newClaimFrom(creditor, ClaimBinding.Unbound);
        vm.stopPrank();

        assertTrue(claimId == 2 && claim.binding == ClaimBinding.Unbound);

        vm.prank(controller);
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

        // test with controller
        vm.startPrank(controller);
        // make a new claim
        (claimId, claim) = _newClaimFrom(creditor, ClaimBinding.BindingPending);
        vm.stopPrank();

        assertTrue(claimId == 2 && claim.binding == ClaimBinding.BindingPending);

        vm.prank(controller);
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
        vm.expectRevert(BullaClaimValidationLib.ClaimBound.selector);
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        // in the case of trying to set the claim to binding pending
        vm.expectRevert(BullaClaimValidationLib.ClaimBound.selector);
        bullaClaim.updateBinding(claimId, ClaimBinding.BindingPending);
        vm.stopPrank();

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Bound);

        // test with controller
        vm.startPrank(controller);
        (claimId,) = _newClaimFrom(creditor, ClaimBinding.Unbound);
        vm.stopPrank();

        vm.prank(controller);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);

        // an controller cannot unbind a debtor
        vm.startPrank(controller);
        vm.expectRevert(BullaClaimValidationLib.ClaimBound.selector);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Unbound);

        vm.expectRevert(BullaClaimValidationLib.ClaimBound.selector);
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

        // test with an controller
        vm.startPrank(controller);
        (claimId,) = _newClaimFrom(creditor, ClaimBinding.Unbound);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        vm.startPrank(controller);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);
    }

    function testCannotUpdateBindingIfNotMinted() public {
        vm.prank(debtor);
        vm.expectRevert(IBullaClaimV2.NotMinted.selector);
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
            vm.expectRevert(BullaClaimValidationLib.ClaimNotPending.selector);
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

    function testControllerCanUpdateToUnboundForCreditor() public {
        // test case: creditor can "free" a debtor from a claim
        vm.startPrank(controller);
        (uint256 claimId,) = _newClaimFrom(creditor, ClaimBinding.BindingPending);
        vm.stopPrank();

        // debtor accepts
        vm.prank(controller);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.Unbound);

        // creditor frees debtor
        vm.prank(controller);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Unbound);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Unbound);

        // (also test bound -> bindingPending)

        // debtor reaccepts
        vm.prank(controller);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);

        vm.expectEmit(true, true, true, true);
        emit BindingUpdated(claimId, creditor, ClaimBinding.BindingPending);

        // the creditor can move the binding back to pending
        vm.prank(controller);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.BindingPending);

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.BindingPending);
    }

    function testCreditorCannotUpdateToBound() public {
        uint256 claimId;
        // test case: a malicous creditor tries to directly bind a debtor after claim creation
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.Unbound);
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.CannotBindClaim.selector);

        // creditor tries to bind
        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // try the above, but for a binding pending claim
        vm.startPrank(creditor);
        (claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.CannotBindClaim.selector);

        vm.prank(creditor);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.startPrank(controller);
        (claimId,) = _newClaimFrom(creditor, ClaimBinding.Unbound);
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.CannotBindClaim.selector);

        // creditor tries to bind
        vm.prank(controller);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Bound);

        // try the above, but for a binding pending claim
        vm.startPrank(controller);
        (claimId,) = _newClaimFrom(creditor, ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.CannotBindClaim.selector);

        vm.prank(controller);
        bullaClaim.updateBindingFrom(creditor, claimId, ClaimBinding.Bound);
    }

    function testNonCreditorOrDebtorCannotUpdateAnything(address caller, uint8 _newBinding) public {
        vm.assume(caller != creditor && caller != debtor);

        ClaimBinding newBinding = ClaimBinding(_newBinding % 3);

        vm.startPrank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);
        vm.stopPrank();

        vm.expectRevert(BullaClaimValidationLib.NotCreditorOrDebtor.selector);

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
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withBinding(ClaimBinding.BindingPending).build()
        );
        vm.stopPrank();

        // creditor can't update the binding directly
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, creditor));
        bullaClaim.updateBinding(claimId, ClaimBinding.Unbound);

        // neither can the debtor
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaimV2.NotController.selector, debtor));
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.prank(controllerAddress);
        bullaClaim.updateBindingFrom(debtor, claimId, ClaimBinding.Bound);
    }

    /// @notice SPEC._spendUpdateBindingApproval.S1
    function testCannotUpdateBindingFromIfUnauthorized() public {
        vm.startPrank(controller);
        (uint256 claimId,) = _newClaimFrom(creditor, ClaimBinding.Unbound);
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert(BullaClaimValidationLib.NotCreditorOrDebtor.selector);
        bullaClaim.updateBindingFrom(controller, claimId, ClaimBinding.BindingPending);
    }
}
