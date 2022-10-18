// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestUpdateBinding is Test {
    WETH public weth;
    BullaClaim public bullaClaim;

    address contractOwner = address(0xB0b);
    address creditor = address(0x01);
    address debtor = address(0x02);

    function setUp() public {
        weth = new WETH();

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        (bullaClaim,) = (new Deployer()).deploy_test(contractOwner, address(0xfee), LockState.Unlocked, 0);
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

        assertTrue(bullaClaim.getClaim(claimId).binding == ClaimBinding.Bound);
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
    }

    function testNonCreditorOrDebtorCannotUpdateAnything(address rando, uint8 _newBinding) public {
        vm.assume(rando != creditor && rando != debtor);

        ClaimBinding newBinding = ClaimBinding(_newBinding % 3);

        vm.prank(creditor);
        (uint256 claimId,) = _newClaim(ClaimBinding.BindingPending);

        vm.expectRevert(abi.encodeWithSignature("NotCreditorOrDebtor(address)", rando));

        vm.prank(rando);
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
    }
}
