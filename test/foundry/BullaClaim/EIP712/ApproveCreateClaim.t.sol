// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {DeployContracts} from "script/DeployContracts.s.sol";
import "contracts/BullaClaimV2.sol";
import "contracts/interfaces/IBullaClaimV2.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {BullaApprovalRegistry} from "contracts/BullaApprovalRegistry.sol";

/// @title Test the approveCreateClaim function
/// @notice This test covers the direct approval functionality without signatures
/// @notice SPEC:
/// Users can call this function directly to modify their CreateClaimApproval for a controller
/// This function can _approve_ a controller given:
///     A1: approvalType is either CreditorOnly, DebtorOnly, or Approved
///     A2: 0 < `approvalCount` < type(uint64).max -> otherwise: reverts
///
///     A.RES1: The nonce is incremented
///     A.RES2: the isBindingAllowed argument is stored
///     A.RES3: the approvalType argument is stored
///     A.RES4: the approvalCount argument is stored
/// This function can _revoke_ a controller given:
///     R1: approvalType is Unapproved
///     R2: `approvalCount` == 0 -> otherwise: reverts
///     R3: `isBindingAllowed` == false -> otherwise: reverts
///
///     R.RES1: The nonce is incremented
///     R.RES2: the isBindingAllowed argument is deleted
///     R.RES3: the approvalType argument is set to unapproved
///     R.RES4: the approvalCount argument is deleted
contract TestApproveCreateClaim is Test {
    BullaClaimV2 internal bullaClaim;
    IBullaApprovalRegistry internal approvalRegistry;

    event CreateClaimApproved(
        address indexed user,
        address indexed controller,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed,
        uint256 nonce
    );

    function setUp() public {
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        approvalRegistry = bullaClaim.approvalRegistry();
    }

    /// @notice happy path: A.RES1, A.RES2, A.RES3, A.RES4
    function testApprove() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, approvalType, approvalCount, isBindingAllowed, 1);

        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(approvalType));
        assertEq(approval.approvalCount, approvalCount);
        assertEq(approval.isBindingAllowed, isBindingAllowed);
        assertEq(approval.nonce, 1);
    }

    /// @notice test all valid approval types: A1
    function testApproveValidTypes() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        // Test CreditorOnly
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.CreditorOnly));

        // Test DebtorOnly
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.DebtorOnly,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.DebtorOnly));
        assertEq(approval.nonce, 2); // Should increment nonce

        // Test Approved
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.Approved));
        assertEq(approval.nonce, 3); // Should increment nonce
    }

    /// @notice test approval count limits: A2
    function testApproveValidCounts() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        bool isBindingAllowed = true;

        // Test minimum valid count (1)
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: 1,
            isBindingAllowed: isBindingAllowed
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.approvalCount, 1);

        // Test unlimited count (type(uint64).max)
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: type(uint64).max,
            isBindingAllowed: isBindingAllowed
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.approvalCount, type(uint64).max);

        // Test arbitrary valid count
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: 42,
            isBindingAllowed: isBindingAllowed
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.approvalCount, 42);
    }

    /// @notice test invalid approval count: A2 violation
    function testApproveInvalidCount() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        bool isBindingAllowed = true;

        vm.prank(alice);
        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: 0,
            isBindingAllowed: isBindingAllowed
        });
    }

    /// @notice test binding allowed flag variations
    function testApproveBindingAllowed() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        // Test with binding allowed = true
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertTrue(approval.isBindingAllowed);

        // Test with binding allowed = false
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: false
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertFalse(approval.isBindingAllowed);
    }

    /// @notice test revocation: R1, R2, R3, R.RES1, R.RES2, R.RES3, R.RES4
    function testRevoke() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        // First approve
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 5,
            isBindingAllowed: true
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.Approved));
        assertEq(approval.approvalCount, 5);
        assertTrue(approval.isBindingAllowed);
        assertEq(approval.nonce, 1);

        // Now revoke
        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, CreateClaimApprovalType.Unapproved, 0, false, 2);

        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.Unapproved));
        assertEq(approval.approvalCount, 0);
        assertFalse(approval.isBindingAllowed);
        assertEq(approval.nonce, 2); // Should increment nonce
    }

    /// @notice test invalid revocation parameters: R2, R3
    function testRevokeInvalidParams() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        // Test revocation with non-zero count (R2 violation)
        vm.prank(alice);
        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 1,
            isBindingAllowed: false
        });

        // Test revocation with binding allowed = true (R3 violation)
        vm.prank(alice);
        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: true
        });

        // Test both violations
        vm.prank(alice);
        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 1,
            isBindingAllowed: true
        });
    }

    /// @notice test multiple controllers
    function testMultipleControllers() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address charlie = address(0xC44511E);

        // Approve bob
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 1,
            isBindingAllowed: false
        });

        // Approve charlie
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: charlie,
            approvalType: CreateClaimApprovalType.DebtorOnly,
            approvalCount: 5,
            isBindingAllowed: true
        });

        // Check both approvals exist independently
        CreateClaimApproval memory bobApproval = approvalRegistry.getApprovals(alice, bob);
        CreateClaimApproval memory charlieApproval = approvalRegistry.getApprovals(alice, charlie);

        assertEq(uint8(bobApproval.approvalType), uint8(CreateClaimApprovalType.CreditorOnly));
        assertEq(bobApproval.approvalCount, 1);
        assertFalse(bobApproval.isBindingAllowed);
        assertEq(bobApproval.nonce, 1);

        assertEq(uint8(charlieApproval.approvalType), uint8(CreateClaimApprovalType.DebtorOnly));
        assertEq(charlieApproval.approvalCount, 5);
        assertTrue(charlieApproval.isBindingAllowed);
        assertEq(charlieApproval.nonce, 1);
    }

    /// @notice test nonce incrementation
    function testNonceIncrement() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        // Initial nonce should be 0
        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.nonce, 0);

        // First approval
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.nonce, 1);

        // Second approval (update)
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 2,
            isBindingAllowed: false
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.nonce, 2);

        // Revocation
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.nonce, 3);
    }

    /// @notice fuzz test for valid approval parameters
    function testFuzzValidApprovals(
        address controller,
        uint8 approvalTypeRaw,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public {
        vm.assume(controller != address(0));
        vm.assume(approvalTypeRaw >= 1 && approvalTypeRaw <= 3); // Valid approval types except Unapproved
        vm.assume(approvalCount > 0); // Must be > 0 for valid approvals

        address alice = address(0xA11CE);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType(approvalTypeRaw);

        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, controller);
        assertEq(uint8(approval.approvalType), uint8(approvalType));
        assertEq(approval.approvalCount, approvalCount);
        assertEq(approval.isBindingAllowed, isBindingAllowed);
        assertEq(approval.nonce, 1);
    }

    /// @notice fuzz test for invalid approval parameters
    function testFuzzInvalidApprovals(
        address controller,
        uint8 approvalTypeRaw,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public {
        vm.assume(controller != address(0));
        vm.assume(approvalTypeRaw >= 1 && approvalTypeRaw <= 3); // Valid approval types except Unapproved
        vm.assume(approvalCount == 0); // Invalid: must be > 0

        address alice = address(0xA11CE);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType(approvalTypeRaw);

        vm.prank(alice);
        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.approveCreateClaim({
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });
    }

    /// @notice test overwriting existing approval
    function testOverwriteApproval() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        // Initial approval
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 1,
            isBindingAllowed: false
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.CreditorOnly));
        assertEq(approval.approvalCount, 1);
        assertFalse(approval.isBindingAllowed);
        assertEq(approval.nonce, 1);

        // Overwrite with different values
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true
        });

        approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.Approved));
        assertEq(approval.approvalCount, type(uint64).max);
        assertTrue(approval.isBindingAllowed);
        assertEq(approval.nonce, 2);
    }

    /// @notice test zero address controller edge case
    function testZeroAddressController() public {
        address alice = address(0xA11CE);
        address zeroController = address(0);

        // Should be able to approve zero address controller
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: zeroController,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, zeroController);
        assertEq(uint8(approval.approvalType), uint8(CreateClaimApprovalType.Approved));
        assertEq(approval.approvalCount, 1);
        assertTrue(approval.isBindingAllowed);
    }

    /// @notice test multiple users approving same controller
    function testMultipleUsersApproval() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address charlie = address(0xC44511E);
        address controller = address(0x123);

        // Alice approves controller
        vm.prank(alice);
        approvalRegistry.approveCreateClaim({
            controller: controller,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 1,
            isBindingAllowed: false
        });

        // Bob approves same controller with different settings
        vm.prank(bob);
        approvalRegistry.approveCreateClaim({
            controller: controller,
            approvalType: CreateClaimApprovalType.DebtorOnly,
            approvalCount: 5,
            isBindingAllowed: true
        });

        // Check both approvals exist independently
        CreateClaimApproval memory aliceApproval = approvalRegistry.getApprovals(alice, controller);
        CreateClaimApproval memory bobApproval = approvalRegistry.getApprovals(bob, controller);

        assertEq(uint8(aliceApproval.approvalType), uint8(CreateClaimApprovalType.CreditorOnly));
        assertEq(aliceApproval.approvalCount, 1);
        assertFalse(aliceApproval.isBindingAllowed);

        assertEq(uint8(bobApproval.approvalType), uint8(CreateClaimApprovalType.DebtorOnly));
        assertEq(bobApproval.approvalCount, 5);
        assertTrue(bobApproval.isBindingAllowed);

        // Charlie has no approval (default state)
        CreateClaimApproval memory charlieApproval = approvalRegistry.getApprovals(charlie, controller);
        assertEq(uint8(charlieApproval.approvalType), uint8(CreateClaimApprovalType.Unapproved));
        assertEq(charlieApproval.approvalCount, 0);
        assertFalse(charlieApproval.isBindingAllowed);
        assertEq(charlieApproval.nonce, 0);
    }
}
