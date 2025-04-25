// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {Claim, Status, ClaimBinding, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";

contract TestCreateClaim is BullaClaimTestHelper {
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

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        _newClaim(creditor, creditor, debtor);
    }

    /*///////////////////// CREATE CLAIM TESTS /////////////////////*/

    //baseline gas report after 1 mint
    function testBaselineGas__createClaim() public {
        _newClaim(creditor, creditor, debtor);
    }

    function testCreateNativeClaim() public {
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.token, address(0));
    }

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);
        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);
    }

    function testCannotCreateClaimLargerThanMaxUint128() public {
        vm.expectRevert();
        vm.prank(creditor);
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: uint256(type(uint128).max) + 1,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCannotCreateClaimWhenNotCreditorOrDebtor() public {
        vm.expectRevert(BullaClaim.NotCreditorOrDebtor.selector);
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: uint256(type(uint128).max) + 1,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCannotDelegateClaimsManually() public {
        PenalizedClaim controller = new PenalizedClaim(address(bullaClaim));

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor));
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCreateBoundClaim() public {
        // test creation of a pending bound claim
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.BindingPending);

        //test creation of a pending claim that is bound
        vm.prank(debtor);
        uint256 boundClaimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Bound,
                payerReceivesClaimOnPayment: true
            })
        );
        Claim memory boundClaim = bullaClaim.getClaim(boundClaimId);
        assertTrue(boundClaim.binding == ClaimBinding.Bound);
    }

    function testCreateEdgeCase_ZeroDebtor() public {
        uint256 beforeClaimCreation = bullaClaim.currentClaimId();
        uint256 claimId = _newClaim(creditor, creditor, address(0));
        assertEq(bullaClaim.currentClaimId(), claimId);
        assertEq(bullaClaim.currentClaimId(), beforeClaimCreation + 1);
    }

    function testCreateEdgeCase_ZeroDueBy() public {
        uint256 beforeClaimCreation = bullaClaim.currentClaimId();
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: 0,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
        assertEq(bullaClaim.currentClaimId(), claimId);
        assertEq(bullaClaim.currentClaimId(), beforeClaimCreation + 1);
    }

    function testCannotCreateBoundClaimUnlessDebtor() public {
        vm.prank(debtor);

        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Bound,
                payerReceivesClaimOnPayment: true
            })
        );

        vm.expectRevert(BullaClaim.CannotBindClaim.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Bound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCannotCreateClaimWithUintOverflow() public {
        uint256 claimAmount = uint256(type(uint128).max) + 1;
        vm.expectRevert();

        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: claimAmount,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCannotCreateOverDueClaim() public {
        vm.warp(block.timestamp + 6 days);

        uint256 dueBy = block.timestamp - 1 days;
        vm.expectRevert(BullaClaim.InvalidTimestamp.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: dueBy,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCannotCreateZeroAmountClaim() public {
        vm.expectRevert(BullaClaim.ZeroAmount.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 0,
                dueBy: 1 days,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function testCannotCreateBoundClaim() public {
        vm.expectRevert(BullaClaim.CannotBindClaim.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Bound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function test_FUZZ_createClaim(
        bool isInvoice,
        address _creditor,
        address _debtor,
        uint128 claimAmount,
        address token,
        uint40 dueBy,
        uint8 binding,
        bool payerReceivesClaimOnPayment
    ) public {
        vm.assume(dueBy > block.timestamp + 6 days);
        vm.assume(_creditor != address(0));
        vm.assume(claimAmount > 0);
        vm.assume(binding <= 1); // assumes a fuzz can only produce unbound or binding pending claims
        vm.warp(block.timestamp + 6 days);
        vm.roll(10_000);
        uint256 expectedClaimId = bullaClaim.currentClaimId() + 1;

        uint256 creditorBalanceBefore = bullaClaim.balanceOf(_creditor);

        address creator = isInvoice ? _creditor : _debtor;
        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            expectedClaimId,
            creator,
            _creditor,
            _debtor,
            uint256(claimAmount),
            uint256(dueBy),
            "test description",
            token,
            address(0),
            ClaimBinding(binding)
        );

        vm.prank(creator);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "test description",
                claimAmount: claimAmount,
                dueBy: dueBy,
                token: token,
                binding: ClaimBinding(binding),
                payerReceivesClaimOnPayment: payerReceivesClaimOnPayment
            })
        );

        {
            assertEq(bullaClaim.currentClaimId(), claimId);
            Claim memory claim = bullaClaim.getClaim(claimId);
            assertEq(bullaClaim.ownerOf(claimId), _creditor);
            assertEq(claim.paidAmount, 0);
            assertTrue(claim.status == Status.Pending);
            assertEq(claim.claimAmount, claimAmount);
            assertEq(claim.debtor, _debtor);
            assertEq(claim.dueBy, dueBy);
            assertEq(claim.payerReceivesClaimOnPayment, payerReceivesClaimOnPayment);
            assertTrue(claim.binding == ClaimBinding(binding));
            assertEq(claim.token, token);
            assertEq(bullaClaim.balanceOf(_creditor), creditorBalanceBefore + 1);
            assertEq(bullaClaim.ownerOf(claimId), _creditor);

            vm.prank(_creditor);
            bullaClaim.safeTransferFrom(_creditor, address(0xB0B), claimId);

            assertEq(bullaClaim.ownerOf(claimId), address(0xB0B));
        }
    }
}
