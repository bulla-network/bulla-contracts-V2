// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaHelpers} from "contracts/libraries/BullaHelpers.sol";
import {Deployer} from "script/Deployment.s.sol";
import {Claim, Status, ClaimBinding, LockState, CreateClaimParams} from "contracts/types/Types.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

enum BullaClaimState {
    NoOwner,
    HasOwner
}

/// @dev This test ensures a claim's lifecycle remains uneffected by any top-level admin functions ///
///     1. A user should be able to create a claim and have the the claim trade hands any amount of times
///     2. Any user should always be able to pay a claim for the claim determined at the time of claim creation with the creditor receiving tha payment
///     3. Once the user fully pays a claim, it should go to the payer and the claim being marked as paid.
contract TestInvariants is Test {
    WETH public weth;
    BullaClaim public bullaClaim;

    address alice = address(0xA11cE);
    address charlie = address(0xC44511E);

    address contractOwner = address(0xB0b);

    address creditor = address(0x01);
    address debtor = address(0x02);

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        uint256 dueBy,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    event ClaimPayment(uint256 indexed claimId, address indexed paidBy, uint256 paymentAmount, uint256 totalPaidAmount);
    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    function setUp() public {
        weth = new WETH();

        vm.label(address(this), "TEST_CONTRACT");

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(alice, "ALICE");

        vm.prank(contractOwner);
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: contractOwner,
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });

        weth.transferFrom(address(this), creditor, type(uint136).max);
        weth.transferFrom(address(this), debtor, type(uint136).max);

        vm.deal(creditor, type(uint136).max);
        vm.deal(debtor, type(uint136).max);
    }

    function _setState(BullaClaimState state) public {
        vm.startPrank(bullaClaim.owner() == address(0) ? address(0) : contractOwner);

        if (state == BullaClaimState.NoOwner && bullaClaim.owner() != address(0)) {
            bullaClaim.renounceOwnership();
        } else if (state == BullaClaimState.HasOwner) {
            bullaClaim.transferOwnership(contractOwner);
        }

        vm.stopPrank();
    }

    function testInvariantOfClaimLifeCycle(
        uint8 _bullaClaimState1,
        uint8 _bullaClaimState2,
        uint8 _bullaClaimState3,
        uint8 _bullaClaimState4,
        uint128 _claimAmount,
        bool endWithCancellation
    ) public {
        // INITIAL SETUP //

        vm.assume(_claimAmount > 100);

        BullaClaimState state = BullaClaimState(_bullaClaimState1 % 2);
        _setState(state);

        uint256 claimId;
        uint256 fullPaymentAmount;

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(_claimAmount).withDescription("").withToken(address(weth)).build();

        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            bullaClaim.currentClaimId() + 1,
            creditor,
            creditor,
            debtor,
            uint256(_claimAmount),
            uint256(0),
            "",
            address(weth),
            address(0),
            ClaimBinding(ClaimBinding.Unbound)
        );

        vm.prank(creditor);
        claimId = bullaClaim.createClaim(params);

        fullPaymentAmount = _claimAmount;

        // BEGIN TESTS //

        {
            Claim memory claim = bullaClaim.getClaim(claimId);

            assertTrue(claim.status == Status.Pending);
            assertTrue(claim.binding == ClaimBinding.Unbound);
            assertEq(claim.controller, address(0));
            assertEq(claim.token, address(weth));

            assertEq(bullaClaim.balanceOf(creditor), 1);
            assertEq(bullaClaim.ownerOf(claimId), creditor);
            assertEq(bullaClaim.currentClaimId(), claimId);
        }

        state = BullaClaimState(_bullaClaimState2 % 2);
        _setState(state);

        vm.prank(creditor);
        bullaClaim.transferFrom(creditor, alice, claimId);

        assertEq(bullaClaim.balanceOf(alice), 1);
        assertEq(bullaClaim.ownerOf(claimId), alice);

        state = BullaClaimState(_bullaClaimState3 % 2);
        _setState(state);

        if (endWithCancellation) {
            vm.startPrank(alice);

            vm.expectEmit(true, true, true, true, address(bullaClaim));
            emit ClaimRescinded(claimId, address(alice), "nvm");
            bullaClaim.cancelClaim(claimId, "nvm");
            vm.stopPrank();

            return;
        }

        {
            uint256 creditorBalanceBefore = weth.balanceOf(alice);
            uint256 debtorBalanceBefore = weth.balanceOf(debtor);
            uint256 paymentAmount = fullPaymentAmount / 2;

            vm.startPrank(debtor);
            weth.approve(address(bullaClaim), paymentAmount);

            vm.expectEmit(true, true, true, true, address(bullaClaim));
            emit ClaimPayment(claimId, debtor, paymentAmount, paymentAmount);

            bullaClaim.payClaim(claimId, paymentAmount);
            vm.stopPrank();

            Claim memory claim = bullaClaim.getClaim(claimId);

            assertTrue(claim.status == Status.Repaying);
            assertTrue(claim.binding == ClaimBinding.Unbound);
            assertEq(claim.controller, address(0));
            assertEq(claim.token, address(weth));

            assertEq(weth.balanceOf(alice), creditorBalanceBefore + paymentAmount);
            assertEq(weth.balanceOf(debtor), debtorBalanceBefore - paymentAmount);
            assertEq(bullaClaim.balanceOf(alice), 1);
            assertEq(bullaClaim.ownerOf(claimId), alice);
            assertEq(bullaClaim.currentClaimId(), claimId);
        }

        vm.prank(alice);
        bullaClaim.transferFrom(alice, charlie, claimId);

        assertEq(bullaClaim.balanceOf(charlie), 1);
        assertEq(bullaClaim.ownerOf(claimId), charlie);

        state = BullaClaimState(_bullaClaimState4 % 2);
        _setState(state);

        {
            Claim memory claim = bullaClaim.getClaim(claimId);

            uint256 creditorBalanceBefore = weth.balanceOf(charlie);
            uint256 debtorBalanceBefore = weth.balanceOf(debtor);

            uint256 paymentAmount = BullaHelpers.getRemainingPrincipalAmount(bullaClaim, claimId);

            vm.startPrank(debtor);
            weth.approve(address(bullaClaim), paymentAmount);

            vm.expectEmit(true, true, true, true, address(bullaClaim));
            emit ClaimPayment(claimId, debtor, paymentAmount, _claimAmount);
            bullaClaim.payClaim(claimId, paymentAmount);
            vm.stopPrank();

            claim = bullaClaim.getClaim(claimId);

            assertTrue(claim.status == Status.Paid);
            assertTrue(claim.binding == ClaimBinding.Unbound);
            assertEq(claim.controller, address(0));
            assertEq(claim.token, address(weth));
            assertEq(claim.claimAmount, claim.paidAmount);

            assertEq(weth.balanceOf(charlie), creditorBalanceBefore + paymentAmount);
            assertEq(weth.balanceOf(debtor), debtorBalanceBefore - paymentAmount);
            assertEq(bullaClaim.balanceOf(alice), 0);
            assertEq(bullaClaim.ownerOf(claimId), debtor);
            assertEq(bullaClaim.balanceOf(debtor), 1);
            assertEq(bullaClaim.currentClaimId(), claimId);
        }
    }
}
