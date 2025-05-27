// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim, CreateClaimApprovalType} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

/// @notice SPEC:
/// A function can call this function to verify and "spend" `from`'s approval of `operator` to create a claim given the following:
///     S1. `operator` has > 0 approvalCount from the `from` address -> otherwise: reverts
///     S2. The creditor and debtor arguments are permissed by the `from` address, meaning:
///         - If the approvalType is `CreditorOnly` the `from` address must be the creditor -> otherwise: reverts
///         - If the approvalType is `DebtorOnly` the `from` address must be the debtor -> otherwise: reverts
///        Note: If the approvalType is `Approved`, the `operator` may specify the `from` address as the creditor, or the debtor.
///     S3. If the claimBinding argument is `Bound`, then the isBindingAllowed permission must be set to true -> otherwise: reverts
///        Note: _createClaim will always revert if the claimBinding argument is `Bound` and the `from` address is not the debtor
///
/// RES1: If the above are true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return -> otherwise: no-op
contract TestCreateClaimFrom is BullaClaimTestHelper {
    uint256 creditorPK = uint256(0x01);

    address creditor = vm.addr(creditorPK);
    address debtor = address(0x02);

    uint256 userPK = uint256(0xA11c3);
    address user = vm.addr(userPK);
    address operator = address(0xb0b);

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        _newClaim(creditor, creditor, debtor);
    }

    ///////// CREATE CLAIM FROM TESTS /////////

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        _permitCreateClaim({_userPK: userPK, _operator: address(this), _approvalCount: type(uint64).max});

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimFrom(user, creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);
        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimFrom(user, creditor, debtor);
    }

    /// @notice SPEC.S1
    function testCreateClaim() public {
        // have the creditor permit bob to act as a operator
        _permitCreateClaim({_userPK: userPK, _operator: operator, _approvalCount: 1});

        (CreateClaimApproval memory approval,,,,) = bullaClaim.approvals(user, operator);
        uint256 approvalCount = approval.approvalCount;

        vm.prank(operator);
        _newClaimFrom(user, user, debtor);
        (approval,,,,) = bullaClaim.approvals(user, operator);

        assertEq(approval.approvalCount, approvalCount - 1);
    }

    function testCreateDelegatedClaim() public {
        PenalizedClaim controller = new PenalizedClaim(address(bullaClaim));
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(controller),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(controller),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.startPrank(creditor);
        uint256 claimId = controller.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.controller, address(controller));
    }

    /// @notice SPEC.S1
    function testCannotCreateFromNonExtension() public {
        address rando = address(0x1247765432);

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector));
        vm.prank(rando);
        _newClaimFrom(creditor, creditor, debtor);
    }

    /// @notice SPEC.S1
    function testCannotOverspendApprovals() public {
        // approvalCount is only 1
        _permitCreateClaim({_userPK: userPK, _operator: operator, _approvalCount: 1});

        vm.startPrank(operator);
        _newClaimFrom(user, user, debtor);
        // approval is now 0
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector));
        _newClaimFrom(user, user, debtor);
        vm.stopPrank();
    }

    /// @notice SPEC.RES2
    function testOperatorWillBeUnapprovedWhenApprovalRunsOut() public {
        _permitCreateClaim({_userPK: userPK, _operator: operator, _approvalCount: 2});

        vm.prank(operator);
        _newClaimFrom(user, user, debtor);

        vm.prank(operator);
        _newClaimFrom(user, user, debtor);

        (CreateClaimApproval memory approval,,,,) = bullaClaim.approvals(user, operator);

        assertEq(approval.approvalCount, 0);
        assertTrue(approval.approvalType == CreateClaimApprovalType.Unapproved);
    }

    /// @notice SPEC.RES1
    function testuint64MaxApprovalDoesNotDecrement() public {
        _permitCreateClaim({_userPK: userPK, _operator: operator, _approvalCount: type(uint64).max});

        vm.prank(operator);
        _newClaimFrom(user, user, debtor);

        (CreateClaimApproval memory approval,,,,) = bullaClaim.approvals(user, operator);

        assertEq(approval.approvalCount, type(uint64).max);
    }

    /// @notice SPEC.S2
    function testCannotCreateCreditorClaimWhenDebtorOnlyApproval() public {
        _permitCreateClaim({
            _userPK: userPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        _newClaimFrom({_from: user, _creditor: user, _debtor: debtor});
    }

    /// @notice SPEC.S2
    function testCannotCreateDebtorClaimWhenCreditorOnlyApproval() public {
        _permitCreateClaim({
            _userPK: userPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        _newClaimFrom({_from: user, _creditor: user, _debtor: debtor});
    }

    /// @notice SPEC.S3
    function testCannotCreateBoundClaimWhenUnapproved() public {
        _permitCreateClaim({
            _userPK: userPK,
            _operator: operator,
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: false // binding is not allowed
        });

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(user).withDebtor(debtor).withToken(
            address(weth)
        ).withBinding(ClaimBinding.Bound).build();

        vm.prank(operator);
        vm.expectRevert(BullaClaim.CannotBindClaim.selector);
        bullaClaim.createClaimFrom(user, params);
    }

    function test_fuzz_createClaimApprovals(
        uint256 pk,
        address _operator,
        uint64 _approvalCount,
        uint8 _approvalType,
        bool _isBindingAllowed,
        bool isInvoice
    ) public {
        CreateClaimApprovalType approvalType = CreateClaimApprovalType(_approvalType % 3);

        vm.assume(privateKeyValidity(pk));
        vm.assume(_approvalCount > 0 && approvalType != CreateClaimApprovalType.Unapproved);

        address _user = vm.addr(pk);
        _permitCreateClaim({
            _userPK: pk,
            _operator: _operator,
            _approvalCount: _approvalCount,
            _approvalType: approvalType,
            _isBindingAllowed: _isBindingAllowed
        });

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(isInvoice ? _user : debtor)
            .withDebtor(isInvoice ? debtor : _user).withDescription("fuzzzin").withToken(address(0)).withBinding(
            _isBindingAllowed && !isInvoice ? ClaimBinding.Bound : ClaimBinding.Unbound
        ).build();

        if (
            (approvalType == CreateClaimApprovalType.CreditorOnly && !isInvoice)
                || (approvalType == CreateClaimApprovalType.DebtorOnly && isInvoice)
        ) {
            vm.expectRevert(BullaClaim.NotApproved.selector);
        } else {
            vm.expectEmit(true, true, true, true);
            emit ClaimCreated(
                bullaClaim.currentClaimId() + 1,
                _user,
                isInvoice ? _user : debtor,
                isInvoice ? debtor : _user,
                1 ether,
                "fuzzzin",
                address(0),
                _operator,
                _isBindingAllowed && !isInvoice ? ClaimBinding.Bound : ClaimBinding.Unbound
            );
        }

        vm.prank(_operator);
        bullaClaim.createClaimFrom(_user, params);
    }
}
