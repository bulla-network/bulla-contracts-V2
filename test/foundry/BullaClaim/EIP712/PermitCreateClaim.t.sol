// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {EIP712Helper, privateKeyValidity, splitSig} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import "contracts/BullaClaim.sol";
import "contracts/mocks/PenalizedClaim.sol";
import "contracts/mocks/ERC1271Wallet.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

/// @title Test the permitCreateClaim function
/// @notice This test covers happy paths, fuzzes and tests against some common signature system pitfalls:
///     1. Phantom approvals to the 0 address
///     2. Replayed signature
///     3. Replayed signature (after deletion of any storage variables)
///     4. Malicious approval signature from another user
/// @notice SPEC:
/// Anyone can call this function with a valid signature to modify the `user`'s CreateClaimApproval of `operator` to the provided arguments
/// In all cases:
///     SIG1: The recovered signer from the EIP712 signature == `user`
///     SIG2: `user` is not a 0 address
///     SIG3: `extensionRegistry` is not address(0)
/// This function can _approve_ an operator given:
///     A1: approvalType is either CreditorOnly, DebtorOnly, or Approved
///     A2: 0 < `approvalCount` < type(uint64).max -> otherwise: reverts
///
///     A.RES1: The nonce is incremented
///     A.RES2: the isBindingAllowed argument is stored
///     A.RES3: the approvalType argument is stored
///     A.RES4: the approvalCount argument is stored
/// This function can _revoke_ an operator given:
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
///     S3: The `operator` address
///     S4: A verbose approval message: see `BullaClaimPermitLib.getPermitCreateClaimMessage()`
///     S5: The `approvalType` enum as a uint8
///     S6: The `approvalCount`
///     S7: The `isBindingAllowed` boolean flag
///     S8: The stored signing nonce found in `user`'s CreateClaimApproval struct for `operator`
contract TestPermitCreateClaim is Test {
    BullaClaim internal bullaClaim;
    EIP712Helper internal sigHelper;
    ERC1271WalletMock internal eip1271Wallet;

    event CreateClaimApproved(
        address indexed user,
        address indexed operator,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    function setUp() public {
        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
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
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, approvalType, approvalCount, isBindingAllowed);

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: signature
        });

        (CreateClaimApproval memory approval,,,) = bullaClaim.approvals(alice, bob);

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
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });
        eip1271Wallet.sign(digest);

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, approvalType, approvalCount, isBindingAllowed);

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: bytes("")
        });

        (CreateClaimApproval memory approval,,,) = bullaClaim.approvals(alice, bob);

        assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertTrue(approval.approvalCount == approvalCount, "approvalCount");
        assertTrue(approval.nonce == 1, "approvalCount");
    }

    /// @notice happy path: R.RES1, R.RES2, R.RES3
    function testRevoke() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
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
            false
        );
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: signature
        });

        (CreateClaimApproval memory approval,,,) = bullaClaim.approvals(alice, bob);
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
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });
        eip1271Wallet.sign(digest);

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: bytes("")
        });

        digest = sigHelper.getPermitCreateClaimDigest({
            user: alice,
            operator: bob,
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
            false
        );

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: bytes("")
        });

        (CreateClaimApproval memory approval,,,) = bullaClaim.approvals(alice, bob);
        assertEq(approval.approvalCount, 0, "approvalCount");
        assertTrue(approval.approvalType == CreateClaimApprovalType.Unapproved, "approvalType");
        assertTrue(approval.isBindingAllowed == false, "bindingAllowed");
    }

    /// @notice SPEC.R2
    function testCannotHaveApprovalCountGreaterThan0WhenRevoking() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 1,
            isBindingAllowed: false
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
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

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
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
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: signature
        });

        signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.CreditorOnly,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: signature
        });

        signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.DebtorOnly,
            approvalCount: 0,
            isBindingAllowed: true
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
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

        BullaExtensionRegistry(bullaClaim.extensionRegistry()).setExtensionName(bob, "bobby bob");

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalType: approvalType,
                approvalCount: approvalCount,
                isBindingAllowed: isBindingAllowed
            })
        });
    }

    /// @notice SPEC.A4
    function testCannotPermitWhenExtensionRegistryUnset() public {
        uint256 alicePK = uint256(0xA11c3);

        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            user: bob,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        bullaClaim.setExtensionRegistry(address(0));

        // This call to the 0 address will fail
        vm.expectRevert();
        bullaClaim.permitCreateClaim({
            user: bob,
            operator: bob,
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
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });
        signature[64] = bytes1(uint8(signature[64]) + 1);

        vm.expectRevert(BullaClaim.InvalidSignature.selector);

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
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
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        // sign the digest with the wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badGuyPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
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
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });

        // alice then revokes her approval
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Unapproved,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalType: CreateClaimApprovalType.Unapproved,
                approvalCount: 0,
                isBindingAllowed: false
            })
        });

        // the initial signature can not be used to re-permit
        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCreateClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice SPEC.SIG2
    function testCannotPermitThe0Address() public {
        address user = address(0);
        address operator = vm.addr(0xBeefCafe);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        bytes memory signature = sigHelper.signCreateClaimPermit({
            pk: uint256(12345),
            user: user,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });
        signature[64] = bytes1(uint8(signature[64]) + 90);
        // the above corrupt signature will return a 0 from ecrecover

        (uint8 v, bytes32 r, bytes32 s) = splitSig(signature);

        assertEq(
            ecrecover(sigHelper.getPermitCreateClaimDigest(user, operator, approvalType, approvalCount, true), v, r, s),
            user,
            "ecrecover sanity check"
        );

        vm.expectRevert(BullaClaim.InvalidSignature.selector);

        bullaClaim.permitCreateClaim({
            user: user,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    /// @notice sanity check to ensure that existance of code at the operator address doesn't break anything
    function testCanPermitSmartContract() public {
        PenalizedClaim operator = new PenalizedClaim(address(bullaClaim));
        uint256 alicePK = uint256(0xA11c3);

        bullaClaim.permitCreateClaim({
            user: vm.addr(alicePK),
            operator: address(operator),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                user: vm.addr(alicePK),
                operator: address(operator),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });
    }

    function test_fuzz_permitAndRescindCreateClaimFrom(
        uint256 pk,
        uint256 operatorPK,
        bool isBindingAllowed,
        uint8 _approvalType,
        uint64 approvalCount,
        bool registerContract
    ) public {
        CreateClaimApprovalType approvalType = CreateClaimApprovalType(_approvalType % 2);
        vm.assume(pk != operatorPK);
        vm.assume(privateKeyValidity(pk));
        vm.assume(privateKeyValidity(operatorPK));

        // ensure no conflicts between revert states
        vm.assume(
            approvalType == CreateClaimApprovalType.Unapproved
                ? approvalCount == 0 && !isBindingAllowed
                : approvalCount > 0
        );

        address user = vm.addr(pk);
        address operator = vm.addr(operatorPK);

        if (registerContract) {
            BullaExtensionRegistry(bullaClaim.extensionRegistry()).setExtensionName(operator, "BullaFake");
        }

        bytes memory sig = sigHelper.signCreateClaimPermit({
            pk: pk,
            user: user,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(user, operator, approvalType, approvalCount, isBindingAllowed);

        bullaClaim.permitCreateClaim({
            user: user,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sig
        });

        (CreateClaimApproval memory approval,,,) = bullaClaim.approvals(user, operator);

        assertEq(approval.nonce, 1, "nonce");
        assertEq(approval.approvalCount, approvalCount, "approvalCount");

        // storage is deleted on approvalCount == 0 (revoke case)
        if (approvalCount > 0) {
            assertTrue(approval.approvalType == approvalType, "approvalType");
            assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        }
    }
}
