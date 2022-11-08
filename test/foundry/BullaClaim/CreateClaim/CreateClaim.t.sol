// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

contract CreateClaimTest is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    BullaFeeCalculator feeCalculator;

    address creditor = address(0x01);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    event ClaimCreated(
        uint256 indexed claimId,
        address caller,
        address indexed creditor,
        address indexed debtor,
        string description,
        uint256 claimAmount,
        address claimToken,
        ClaimBinding binding,
        uint256 dueBy,
        uint256 feeCalculatorId
    );

    function setUp() public {
        weth = new WETH();

        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        _newClaim(creditor, debtor);
    }

    /*///////// HELPERS /////////*/
    function _enableFee() private {
        feeCalculator = new BullaFeeCalculator(500);
        bullaClaim.setFeeCalculator(address(feeCalculator));
    }

    function _newClaim(address _creditor, address _debtor) private returns (uint256 claimId) {
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
    }

    /*///////////////////// CREATE CLAIM TESTS /////////////////////*/

    //baseline gas report after 1 mint
    function testBaselineGas__createClaim() public {
        _newClaim(creditor, debtor);
    }

    function testCreateNativeClaim() public {
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.token, address(0));
    }

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);
        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, debtor);
    }

    function testCannotCreateClaimLargerThanMaxUint128() public {
        vm.expectRevert();
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: uint256(type(uint128).max) + 1,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
    }

    function testCannotDelegateClaimsManually() public {
        PenalizedClaim delegator = new PenalizedClaim(address(bullaClaim));

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSignature("NotDelegator(address)", debtor));
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(delegator),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
    }

    function testCreateBoundClaim() public {
        // test creation of a pending bound claim
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.BindingPending
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
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound
            })
        );
        Claim memory boundClaim = bullaClaim.getClaim(boundClaimId);
        assertTrue(boundClaim.binding == ClaimBinding.Bound);
    }

    function testCreateEdgeCase_ZeroDebtor() public {
        uint256 beforeClaimCreation = bullaClaim.currentClaimId();
        uint256 claimId = _newClaim(creditor, address(0));
        assertEq(bullaClaim.currentClaimId(), claimId);
        assertEq(bullaClaim.currentClaimId(), beforeClaimCreation + 1);
    }

    function testCreateEdgeCase_ZeroAmount() public {
        uint256 beforeClaimCreation = bullaClaim.currentClaimId();
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 0,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(bullaClaim.currentClaimId(), beforeClaimCreation + 1);
        assertEq(bullaClaim.currentClaimId(), claimId);
        assertEq(claim.claimAmount, 0);
    }

    function testCreateEdgeCase_ZeroDueBy() public {
        uint256 beforeClaimCreation = bullaClaim.currentClaimId();
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: 0,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
        assertEq(bullaClaim.currentClaimId(), claimId);
        assertEq(bullaClaim.currentClaimId(), beforeClaimCreation + 1);
    }

    function testCannotCreateDelegatedClaimWithBadDelegator() public {
        address delegator = address(0xDECAFC0FFEE);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSignature("NotDelegator(address)", debtor));

        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(delegator),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound
            })
        );
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
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound
            })
        );

        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound
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
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
    }

    function testCannotCreateOverDueClaim() public {
        vm.warp(block.timestamp + 6 days);

        uint256 dueBy = block.timestamp - 1 days;
        vm.expectRevert(abi.encodeWithSignature("InvalidTimestamp(uint256)", dueBy));
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: dueBy,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
    }

    function testCannotCreateBoundClaim() public {
        vm.expectRevert(abi.encodeWithSignature("CannotBindClaim()"));
        bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound
            })
        );
    }

    function test_FUZZ_createClaim(
        address _creditor,
        address _debtor,
        string calldata description,
        uint128 claimAmount,
        address token,
        uint40 dueBy,
        uint8 binding
    ) public {
        uint256 blockTime = block.timestamp + 6 days;

        vm.assume(dueBy > blockTime);
        vm.assume(_creditor != address(0));
        vm.assume(binding <= 1); // assumes a fuzz can only produce unbound or binding pending claims
        vm.warp(blockTime);
        vm.roll(10_000);
        uint256 expectedClaimId = bullaClaim.currentClaimId() + 1;

        uint256 creditorBalanceBefore = bullaClaim.balanceOf(_creditor);

        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            expectedClaimId,
            address(this),
            _creditor,
            _debtor,
            description,
            uint256(claimAmount),
            token,
            ClaimBinding(binding),
            uint256(dueBy),
            bullaClaim.currentFeeCalculatorId()
            );

        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: description,
                claimAmount: claimAmount,
                dueBy: dueBy,
                token: token,
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding(binding)
            })
        );

        assertEq(bullaClaim.currentClaimId(), claimId);
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(bullaClaim.ownerOf(claimId), _creditor);
        assertEq(claim.paidAmount, 0);
        assertTrue(claim.status == Status.Pending);
        assertEq(claim.claimAmount, claimAmount);
        assertEq(claim.debtor, _debtor);
        assertEq(uint256(claim.feeCalculatorId), 0);
        assertEq(claim.dueBy, dueBy);
        assertTrue(claim.binding == ClaimBinding(binding));
        assertEq(claim.token, token);
        assertEq(bullaClaim.balanceOf(_creditor), creditorBalanceBefore + 1);
        assertEq(bullaClaim.ownerOf(claimId), _creditor);

        vm.prank(_creditor);
        bullaClaim.safeTransferFrom(_creditor, address(0xB0B), claimId);

        assertEq(bullaClaim.ownerOf(claimId), address(0xB0B));
    }

    function testCreateClaimEnsureFeeCalculator() public {
        _enableFee();
        uint256 claimId = _newClaim(creditor, debtor);
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.feeCalculatorId, uint256(claim.feeCalculatorId));
    }
}
