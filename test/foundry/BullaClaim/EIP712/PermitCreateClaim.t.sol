// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {EIP712Helper, privateKeyValidity, splitSig} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import "contracts/BullaClaimV2.sol";
import "contracts/interfaces/IBullaClaimV2.sol";
import "contracts/mocks/PenalizedClaim.sol";
import "contracts/mocks/ERC1271Wallet.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {BullaApprovalRegistry} from "contracts/BullaApprovalRegistry.sol";

/// @title Test the permitCreateClaim function
/// @notice This test covers happy paths, fuzzes and tests against some common signature system pitfalls:
///     1. Phantom approvals to the 0 address
///     2. Replayed signature
///     3. Replayed signature (after deletion of any storage variables)
///     4. Malicious approval signature from another user
/// @notice SPEC:
/// Anyone can call this function with a valid signature to modify the `user`'s CreateClaimApproval of `controller` to the provided arguments
/// In all cases:
///     SIG1: The recovered signer from the EIP712 signature == `user`
///     SIG2: `user` is not a 0 address
///     SIG3: `controllerRegistry` is not address(0)
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
///
/// A valid approval signature is defined as: a signed EIP712 hash digest of the following arguments:
///     S1: The hash of the EIP712 typedef string
///     S2: The `user` address
///     S3: The `controller` address
///     S4: A verbose approval message: see `BullaClaimPermitLib.getPermitCreateClaimMessage()`
///     S5: The `approvalType` enum as a uint8
///     S6: The `approvalCount`
///     S7: The `isBindingAllowed` boolean flag
///     S8: The stored signing nonce found in `user`'s CreateClaimApproval struct for `controller`
contract TestPermitCreateClaim is Test {
    BullaClaimV2 internal bullaClaim;
    IBullaApprovalRegistry internal approvalRegistry;
    EIP712Helper internal sigHelper;
    ERC1271WalletMock internal eip1271Wallet;

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
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        approvalRegistry = bullaClaim.approvalRegistry();
        sigHelper = new EIP712Helper(address(bullaClaim));
        eip1271Wallet = new ERC1271WalletMock();
    }

    /// @notice happy path: A.RES1, A.RES2, A.RES3
    function testPermit() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, approvalType, approvalCount, isBindingAllowed, 1);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: signature
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);

        assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertTrue(approval.approvalCount == approvalCount, "approvalCount");
        assertTrue(approval.nonce == 1, "approvalCount");
    }

    function testPermitEip1271() public {
        address alice = address(eip1271Wallet);
        address bob = address(0xB0b);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });
        eip1271Wallet.sign(digest);

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, approvalType, approvalCount, isBindingAllowed, 1);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: bytes("")
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);

        assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertEq(approval.approvalCount, approvalCount, "approvalCount");
        assertTrue(approval.nonce == 1, "approvalCount");
    }

    /// @notice happy path: R.RES1, R.RES2, R.RES3
    function testRevoke() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false
        });

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(
            alice,
            bob,
            CreateClaimApprovalType.Unapproved,
            0, // revoke case
            false,
            2
        );
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: signature
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.approvalCount, 0, "approvalCount");
        assertTrue(approval.approvalType == CreateClaimApprovalType.Unapproved, "approvalType");
    }

    function testRevokeEIP1271() public {
        address alice = address(eip1271Wallet);
        address bob = address(0xB0b);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });
        eip1271Wallet.sign(digest);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: bytes("")
        });

        digest = sigHelper.getPermitCreateClaimDigest({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false
        });
        eip1271Wallet.sign(digest);

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(
            alice,
            bob,
            CreateClaimApprovalType.Unapproved,
            0, // revoke case
            false,
            2
        );

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: bytes("")
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(alice, bob);
        assertEq(approval.approvalCount, 0, "approvalCount");
        assertTrue(approval.approvalType == CreateClaimApprovalType.Unapproved, "approvalType");
        assertTrue(approval.isBindingAllowed == false, "bindingAllowed");
    }

    /// @notice SPEC.R2
    function testCannotHaveApprovalCountGreaterThan0WhenRevoking() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 1,
            isBindingAllowed: false
        });

        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: signature
        });
    }

    /// @notice SPEC.R3
    function testCannotHaveIsBindingAllowedWhenRevoking() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice SPEC.A2
    function testCannotPermitIfApprovalCountIs0() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: signature
        });

        signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: signature
        });

        signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.DebtorOnly,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(IBullaApprovalRegistry.InvalidApproval.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.DebtorOnly,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: signature
        });
    }

    function testPermitRegisteredContract() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        approvalRegistry.controllerRegistry().setControllerName(bob, "bobby bob");

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: bob,
                approvalType: approvalType,
                approvalCount: approvalCount,
                isBindingAllowed: isBindingAllowed
            })
        });
    }

    /// @notice SPEC.A4
    function testCannotPermitWhenControllerRegistryUnset() public {
        uint256 alicePK = uint256(0xA11c3);

        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: bob,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        approvalRegistry.setControllerRegistry(address(0));

        // This call to the 0 address will fail
        vm.expectRevert();
        approvalRegistry.permitCreateClaim({
            user: bob,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: signature
        });
    }

    /// @notice SPEC.SIG1
    function testCannotUseCorruptSig() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });
        signature[64] = bytes1(uint8(signature[64]) + 1);

        vm.expectRevert(IBullaApprovalRegistry.InvalidSignature.selector);

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice SPEC.SIG1
    function testCannotUseWrongSig() public {
        uint256 badGuyPK = uint256(0xBEEF);

        address alice = address(0xA11c3);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        // build a digest based on alice's approval
        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        // sign the digest with the wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badGuyPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IBullaApprovalRegistry.InvalidSignature.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice SPEC.SIG1
    function testCannotReplaySig() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });

        // alice then revokes her approval
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: bob,
                approvalType: CreateClaimApprovalType.Unapproved,
                approvalCount: 0,
                isBindingAllowed: false
            })
        });

        // the initial signature can not be used to re-permit
        vm.expectRevert(IBullaApprovalRegistry.InvalidSignature.selector);
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice SPEC.SIG2
    function testCannotPermitThe0Address() public {
        address user = address(0);
        address controller = vm.addr(0xBeefCafe);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: uint256(12345),
            user: user,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });
        signature[64] = bytes1(uint8(signature[64]) + 90);
        // the above corrupt signature will return a 0 from ecrecover

        (uint8 v, bytes32 r, bytes32 s) = splitSig(signature);

        assertEq(
            ecrecover(
                sigHelper.getPermitCreateClaimDigest(user, controller, approvalType, approvalCount, true), v, r, s
            ),
            user,
            "ecrecover sanity check"
        );

        vm.expectRevert(IBullaApprovalRegistry.InvalidSignature.selector);

        approvalRegistry.permitCreateClaim({
            user: user,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice sanity check to ensure that existance of code at the controller address doesn't break anything
    function testCanPermitSmartContract() public {
        PenalizedClaim controller = new PenalizedClaim(address(bullaClaim));
        uint256 alicePK = uint256(0xA11c3);

        approvalRegistry.permitCreateClaim({
            user: vm.addr(alicePK),
            controller: address(controller),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: vm.addr(alicePK),
                controller: address(controller),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });
    }

    function test_fuzz_permitAndRescindCreateClaimFrom(
        uint256 pk,
        uint256 controllerPK,
        bool isBindingAllowed,
        uint8 _approvalType,
        uint64 approvalCount,
        bool registerContract
    ) public {
        CreateClaimApprovalType approvalType = CreateClaimApprovalType(_approvalType % 2);
        vm.assume(pk != controllerPK);
        vm.assume(privateKeyValidity(pk));
        vm.assume(privateKeyValidity(controllerPK));

        // ensure no conflicts between revert states
        vm.assume(
            approvalType == CreateClaimApprovalType.Unapproved
                ? approvalCount == 0 && !isBindingAllowed
                : approvalCount > 0
        );

        address user = vm.addr(pk);
        address controller = vm.addr(controllerPK);

        if (registerContract) {
            approvalRegistry.controllerRegistry().setControllerName(controller, "BullaFake");
        }

        bytes memory sig = sigHelper.signCreateClaimPermit({
            pk: pk,
            user: user,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(user, controller, approvalType, approvalCount, isBindingAllowed, 1);

        approvalRegistry.permitCreateClaim({
            user: user,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sig
        });

        CreateClaimApproval memory approval = approvalRegistry.getApprovals(user, controller);

        assertEq(approval.nonce, 1, "nonce");
        assertEq(approval.approvalCount, approvalCount, "approvalCount");

        // storage is deleted on approvalCount == 0 (revoke case)
        if (approvalCount > 0) {
            assertTrue(approval.approvalType == approvalType, "approvalType");
            assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        }
    }

    /// @notice Test that IBullaClaimV2.permitCreateClaim works identically to BullaClaim.permitCreateClaim
    /// @dev This test ensures the interface version (using uint8) produces the same results as the direct implementation (using enum)
    function testInterfaceVsImplementationEquivalence() public {
        uint256 alicePK = uint256(0xA11c3);
        uint256 charliePK = uint256(0xC4a11e);

        address alice = vm.addr(alicePK);
        address charlie = vm.addr(charliePK);
        address controller1 = address(0xB0b1);
        address controller2 = address(0xB0b2);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 5;
        bool isBindingAllowed = true;

        // Generate signatures for both users
        bytes memory aliceSignature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            controller: controller1,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        bytes memory charlieSignature = sigHelper.signCreateClaimPermit({
            pk: charliePK,
            user: charlie,
            controller: controller2,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        // Call via direct implementation (BullaClaim.permitCreateClaim with enum)
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: controller1,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: aliceSignature
        });

        // Call via interface (IBullaClaimV2.permitCreateClaim with uint8)
        BullaApprovalRegistry(address(approvalRegistry)).permitCreateClaim({
            user: charlie,
            controller: controller2,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: charlieSignature
        });

        // Verify both calls produced identical results
        CreateClaimApproval memory aliceApproval = approvalRegistry.getApprovals(alice, controller1);
        CreateClaimApproval memory charlieApproval = approvalRegistry.getApprovals(charlie, controller2);

        // Both should have identical state
        assertEq(aliceApproval.nonce, charlieApproval.nonce, "nonce should be equal");
        assertEq(aliceApproval.approvalCount, charlieApproval.approvalCount, "approvalCount should be equal");
        assertEq(aliceApproval.isBindingAllowed, charlieApproval.isBindingAllowed, "isBindingAllowed should be equal");
        assertTrue(aliceApproval.approvalType == charlieApproval.approvalType, "approvalType should be equal");

        // Both should have the expected values
        assertEq(aliceApproval.nonce, 1, "alice nonce");
        assertEq(aliceApproval.approvalCount, approvalCount, "alice approvalCount");
        assertEq(aliceApproval.isBindingAllowed, isBindingAllowed, "alice isBindingAllowed");
        assertTrue(aliceApproval.approvalType == approvalType, "alice approvalType");

        assertEq(charlieApproval.nonce, 1, "charlie nonce");
        assertEq(charlieApproval.approvalCount, approvalCount, "charlie approvalCount");
        assertEq(charlieApproval.isBindingAllowed, isBindingAllowed, "charlie isBindingAllowed");
        assertTrue(charlieApproval.approvalType == approvalType, "charlie approvalType");
    }

    /// @notice Test edge cases to ensure interface and implementation handle revocations identically
    function testInterfaceRevocationEquivalence() public {
        uint256 alicePK = uint256(0xA11c3);
        uint256 charliePK = uint256(0xC4a11e);

        address alice = vm.addr(alicePK);
        address charlie = vm.addr(charliePK);
        address controller1 = address(0xB0b1);
        address controller2 = address(0xB0b2);

        // First approve both via different methods
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: controller1,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 3,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: controller1,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 3,
                isBindingAllowed: true
            })
        });

        BullaApprovalRegistry(address(approvalRegistry)).permitCreateClaim({
            user: charlie,
            controller: controller2,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 3,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: controller2,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 3,
                isBindingAllowed: true
            })
        });

        // Now revoke both via different methods
        approvalRegistry.permitCreateClaim({
            user: alice,
            controller: controller1,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                controller: controller1,
                approvalType: CreateClaimApprovalType.Unapproved,
                approvalCount: 0,
                isBindingAllowed: false
            })
        });

        BullaApprovalRegistry(address(approvalRegistry)).permitCreateClaim({
            user: charlie,
            controller: controller2,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: controller2,
                approvalType: CreateClaimApprovalType.Unapproved,
                approvalCount: 0,
                isBindingAllowed: false
            })
        });

        // Verify both revocations produced identical results
        CreateClaimApproval memory aliceApproval = approvalRegistry.getApprovals(alice, controller1);
        CreateClaimApproval memory charlieApproval = approvalRegistry.getApprovals(charlie, controller2);

        // Both should be revoked (approvalCount = 0, approvalType = Unapproved)
        assertEq(aliceApproval.nonce, 2, "alice nonce should be 2 after revocation");
        assertEq(charlieApproval.nonce, 2, "charlie nonce should be 2 after revocation");

        assertEq(aliceApproval.approvalCount, 0, "alice approvalCount should be 0");
        assertEq(charlieApproval.approvalCount, 0, "charlie approvalCount should be 0");

        assertEq(aliceApproval.isBindingAllowed, false, "alice isBindingAllowed should be false");
        assertEq(charlieApproval.isBindingAllowed, false, "charlie isBindingAllowed should be false");

        assertTrue(
            aliceApproval.approvalType == CreateClaimApprovalType.Unapproved, "alice approvalType should be Unapproved"
        );
        assertTrue(
            charlieApproval.approvalType == CreateClaimApprovalType.Unapproved,
            "charlie approvalType should be Unapproved"
        );
    }
}
