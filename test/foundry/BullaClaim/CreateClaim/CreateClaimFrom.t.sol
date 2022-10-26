// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {BullaClaim, CreateClaimApprovalType} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

contract CreateClaimTest is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaFeeCalculator feeCalculator;

    uint256 creditorPK = uint256(0x01);

    address creditor = vm.addr(creditorPK);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    uint256 ownerPK = uint256(0xA11c3);
    address owner = vm.addr(ownerPK);
    address operator = address(0xb0b);

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
        sigHelper = new EIP712Helper(address(bullaClaim));
        _newClaim(creditor, debtor);
    }

    ///////// HELPERS /////////

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

    function _newClaimFrom(address _from, address _creditor, address _debtor) private returns (uint256 claimId) {
        claimId = bullaClaim.createClaimFrom(
            _from,
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

    function _permitCreateClaim(
        uint256 _ownerPK,
        address _operator,
        uint64 _approvalCount,
        CreateClaimApprovalType _approvalType,
        bool _isBindingAllowed
    ) private {
        Signature memory sig = sigHelper.signCreateClaimPermit(
            _ownerPK, vm.addr(_ownerPK), _operator, _approvalType, _approvalCount, _isBindingAllowed
        );
        bullaClaim.permitCreateClaim(
            vm.addr(_ownerPK), _operator, _approvalType, _approvalCount, _isBindingAllowed, sig
        );
    }

    function _permitCreateClaim(uint256 _ownerPK, address _operator, uint64 _approvalCount) private {
        _permitCreateClaim(_ownerPK, _operator, _approvalCount, CreateClaimApprovalType.Approved, true);
    }

    ///////// CREATE CLAIM FROM TESTS /////////

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        _permitCreateClaim({_ownerPK: ownerPK, _operator: address(this), _approvalCount: type(uint64).max});

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimFrom(owner, creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);
        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimFrom(owner, creditor, debtor);
    }

    function testCreateClaim() public {
        // have the creditor permit bob to act as a operator
        _permitCreateClaim({_ownerPK: ownerPK, _operator: operator, _approvalCount: 1});

        (CreateClaimApproval memory approval,) = bullaClaim.approvals(owner, operator);
        uint256 approvalCount = approval.approvalCount;

        vm.prank(operator);
        _newClaimFrom(owner, owner, debtor);
        (approval,) = bullaClaim.approvals(owner, operator);

        assertEq(approval.approvalCount, approvalCount - 1);
    }

    function testCreateDelegatedClaim() public {
        PenalizedClaim delegator = new PenalizedClaim(address(bullaClaim));
        bullaClaim.permitCreateClaim({
            owner: creditor,
            operator: address(delegator),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                owner: creditor,
                operator: address(delegator),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(creditor);
        uint256 claimId = delegator.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(delegator),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.delegator, address(delegator));
    }

    /// @notice SPEC.S1
    function testCannotCreateFromNonExtension() public {
        address rando = address(0x1247765432);

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector, rando));
        vm.prank(rando);
        _newClaimFrom(creditor, creditor, debtor);
    }

    /// @notice SPEC.S1
    function testCannotOverspendApprovals() public {
        // approvalCount is only 1
        _permitCreateClaim({_ownerPK: ownerPK, _operator: operator, _approvalCount: 1});

        vm.startPrank(operator);
        _newClaimFrom(owner, owner, debtor);
        // approval is now 0
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector, operator));
        _newClaimFrom(owner, owner, debtor);
        vm.stopPrank();
    }

    /// @notice SPEC.result
    function testuint64MaxApprovalDoesNotDecrement() public {
        _permitCreateClaim({_ownerPK: ownerPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        _newClaimFrom(owner, owner, debtor);

        (CreateClaimApproval memory approval,) = bullaClaim.approvals(owner, operator);

        assertEq(approval.approvalCount, type(uint64).max);
    }

    /// @notice SPEC.S2
    function testCannotCreateCreditorClaimWhenDebtorOnlyApproval() public {
        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        vm.prank(operator);
        vm.expectRevert(BullaClaim.Unauthorized.selector);
        _newClaimFrom({_from: owner, _creditor: owner, _debtor: debtor});
    }

    /// @notice SPEC.S2
    function testCannotCreateDebtorClaimWhenCreditorOnlyApproval() public {
        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        vm.prank(operator);
        vm.expectRevert(BullaClaim.Unauthorized.selector);
        _newClaimFrom({_from: owner, _creditor: owner, _debtor: debtor});
    }

    // TODO: remove once BullaClaim only permits creating claims when from == creditor || from == debtor
    function test_TEMP_canCreateForAnyone() public {
        address rando1 = address(0x1234412577737373733);
        address rando2 = address(0x12faabef8281992);

        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: true
        });

        // create a claim between rando1 and rando2
        vm.prank(operator);
        _newClaimFrom({_from: owner, _creditor: rando1, _debtor: rando2});
    }

    /// @notice SPEC.S3
    function testCannotCreateBoundClaimWhenUnapproved() public {
        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: false // binding is not allowed
        });

        vm.prank(operator);
        vm.expectRevert(BullaClaim.Unauthorized.selector);
        bullaClaim.createClaimFrom(
            owner,
            CreateClaimParams({
                creditor: owner,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound // binding is set to bound
            })
        );
    }

    function test_fuzz_createClaimApprovals(
        uint256 pk,
        address _operator,
        uint64 _approvalCount,
        uint8 _approvalType,
        bool _isBindingAllowed,
        bool isInvoice
    ) public {
        vm.assume(privateKeyValidity(pk));
        vm.assume(_approvalCount > 0);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType(_approvalType % 2);
        address _owner = vm.addr(pk);
        _permitCreateClaim({
            _ownerPK: pk,
            _operator: _operator,
            _approvalCount: _approvalCount,
            _approvalType: approvalType,
            _isBindingAllowed: _isBindingAllowed
        });

        if (
            (approvalType == CreateClaimApprovalType.CreditorOnly && !isInvoice)
                || (approvalType == CreateClaimApprovalType.DebtorOnly && isInvoice)
        ) {
            vm.expectRevert(BullaClaim.Unauthorized.selector);
        }

        vm.prank(_operator);
        bullaClaim.createClaimFrom(
            _owner,
            CreateClaimParams({
                creditor: isInvoice ? _owner : debtor,
                debtor: isInvoice ? debtor : _owner,
                description: "fuzzzin",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: _isBindingAllowed && !isInvoice ? ClaimBinding.Bound : ClaimBinding.Unbound
            })
        );
    }
}
