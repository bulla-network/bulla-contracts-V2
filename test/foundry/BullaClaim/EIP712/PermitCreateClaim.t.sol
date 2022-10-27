// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import "contracts/BullaClaim.sol";
import "contracts/mocks/PenalizedClaim.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

/// @title Test the permitCreateClaim function
/// @notice This test covers happy paths, fuzzes and tests against some common signature system pitfalls:
///     1. Phantom approvals to the 0 address
///     2. Replayed signature
///     3. Replayed signature (after deletion of any storage variables)
///     4. Malicious approval signature from another user
contract TestPermitCreateClaim is Test {
    BullaClaim internal bullaClaim;
    EIP712Helper internal sigHelper;

    event CreateClaimApproved(
        address indexed owner,
        address indexed operator,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    function setUp() public {
        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
    }

    function testPermit() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(alice, bob, approvalType, approvalCount, isBindingAllowed);

        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalCount: approvalCount,
                isBindingAllowed: isBindingAllowed
            })
        });

        CreateClaimApproval memory approval = bullaClaim.approvals(alice, bob);

        assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertTrue(approval.approvalCount == approvalCount, "approvalCount");
        assertTrue(approval.nonce == 1, "approvalCount");
    }

    function testRevoke() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(
            alice,
            bob,
            CreateClaimApprovalType.Approved,
            0, // revoke case
            true
            );
        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 0,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 0,
                isBindingAllowed: true
            })
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
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalCount: approvalCount,
                isBindingAllowed: isBindingAllowed
            })
        });
    }

    function testCannotUnsetExtensionRegistry() public {
        uint256 alicePK = uint256(0xA11c3);

        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        Signature memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            owner: bob,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        bullaClaim.setExtensionRegistry(address(0));

        // This call to the 0 address will fail
        vm.expectRevert();
        bullaClaim.permitCreateClaim({
            owner: bob,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: signature
        });
    }

    function testCannotUseCorruptSig() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        Signature memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });
        signature.r = bytes32(uint256(signature.r) + 1);

        vm.expectRevert(BullaClaim.InvalidSignature.selector);

        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    function testCannotUseWrongSig() public {
        uint256 badGuyPK = uint256(0xBEEF);

        address alice = address(0xA11c3);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        // build a digest based on alice's approval
        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        // sign the digest with the wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badGuyPK, digest);
        Signature memory signature = Signature({v: v, r: r, s: s});

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    function testCannotReplaySig() public {
        uint256 alicePK = uint256(0xA11c3);

        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        Signature memory signature = sigHelper.signCreateClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });

        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });

        // alice then revokes her approval
        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: 0,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalCount: 0,
                isBindingAllowed: false
            })
        });

        // the initial signature can not be used to re-permit
        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCreateClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true,
            signature: signature
        });
    }

    function testCannotPermitThe0Address() public {
        address operator = vm.addr(0xBeefCafe);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;

        Signature memory signature = sigHelper.signCreateClaimPermit({
            pk: uint256(12345),
            owner: address(0),
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: true
        });
        signature.r = bytes32(uint256(signature.r) + 1);
        // the above corrupt signature will return a 0 from ecrecover

        vm.expectRevert(BullaClaim.InvalidSignature.selector);

        bullaClaim.permitCreateClaim({
            owner: address(0),
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
            owner: vm.addr(alicePK),
            operator: address(operator),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: alicePK,
                owner: vm.addr(alicePK),
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
        vm.assume(pk != operatorPK);
        vm.assume(privateKeyValidity(pk));
        vm.assume(privateKeyValidity(operatorPK));

        address owner = vm.addr(pk);
        address operator = vm.addr(operatorPK);
        CreateClaimApprovalType approvalType = CreateClaimApprovalType(_approvalType % 2);

        if (registerContract) {
            BullaExtensionRegistry(bullaClaim.extensionRegistry()).setExtensionName(operator, "BullaFake");
        }

        vm.expectEmit(true, true, true, true);
        emit CreateClaimApproved(owner, operator, approvalType, approvalCount, isBindingAllowed);

        Signature memory sig = sigHelper.signCreateClaimPermit({
            pk: pk,
            owner: owner,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        bullaClaim.permitCreateClaim({
            owner: owner,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: sig
        });

        CreateClaimApproval memory approval = bullaClaim.approvals(owner, operator);

        assertEq(approval.nonce, 1, "nonce");
        assertEq(approval.approvalCount, approvalCount, "approvalCount");

        // storage is deleted on approvalCount == 0 (revoke case)
        if (approvalCount > 0) {
            assertTrue(approval.approvalType == approvalType, "approvalType");
            assertEq(approval.isBindingAllowed, isBindingAllowed, "isBindingAllowed");
        }
    }
}
