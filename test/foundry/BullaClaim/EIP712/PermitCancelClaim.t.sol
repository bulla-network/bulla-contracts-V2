// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {EIP712Helper, privateKeyValidity, splitSig} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import "contracts/BullaClaim.sol";
import "contracts/mocks/PenalizedClaim.sol";
import "contracts/mocks/ERC1271Wallet.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

/// @title Test the permitCancelClaim function
/// @notice This test covers happy paths, fuzzes and tests against some common signature system pitfalls:
///     1. Phantom approvals to the 0 address
///     2. Replayed signature
///     3. Malicious approval signature from another user
/// @notice SPEC:
/// A user can specify an operator address to call `cancelClaim` on their behalf under the following conditions:
///     SIG1. The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
///     SIG2. `user` is not the 0 address -> otherwise: reverts
///     SIG3. `extensionRegistry` is not address(0)
/// This function can approve an operator to cancel claims given:
///     AC1: 0 < `approvalCount` < type(uint64).max -> otherwise reverts
/// This function can revoke an operator's approval to cancel claims given:
///     RC1: approvalCount == 0
///
///     RES1: approvalCount is stored
///     RES2: the nonce is incremented
///     RES3: the CancelClaimApproved event is emitted
contract TestPermitCancelClaim is Test {
    BullaClaim internal bullaClaim;
    EIP712Helper internal sigHelper;
    ERC1271WalletMock internal eip1271Wallet;

    event CancelClaimApproved(address indexed user, address indexed operator, uint256 approvalCount);

    function setUp() public {
        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
        eip1271Wallet = new ERC1271WalletMock();
    }

    /// @notice happy path: RES1,2,3
    function testPermit(uint64 approvalCount) public {
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        vm.expectEmit(true, true, true, true);
        emit CancelClaimApproved(alice, bob, approvalCount);

        bullaClaim.permitCancelClaim({
            user: alice,
            operator: bob,
            approvalCount: approvalCount,
            signature: sigHelper.signCancelClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalCount: approvalCount
            })
        });

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertTrue(approval.approvalCount == approvalCount, "approvalCount");
        assertTrue(approval.nonce == 1, "approvalCount");
    }

    function testPermitEIP1271(uint64 approvalCount) public {
        address alice = address(eip1271Wallet);
        address bob = address(0xB0b);

        bytes32 digest =
            sigHelper.getPermitCancelClaimDigest({user: alice, operator: bob, approvalCount: approvalCount});
        eip1271Wallet.sign(digest);

        vm.expectEmit(true, true, true, true);
        emit CancelClaimApproved(alice, bob, approvalCount);

        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: approvalCount, signature: bytes("")});

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertTrue(approval.approvalCount == approvalCount, "approvalCount");
        assertTrue(approval.nonce == 1, "approvalCount");
    }

    // /// @notice SPEC.RC1
    function testRevoke() public {
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bullaClaim.permitCancelClaim({
            user: alice,
            operator: bob,
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: 1})
        });

        vm.expectEmit(true, true, true, true);
        emit CancelClaimApproved(alice, bob, 0);

        bullaClaim.permitCancelClaim({
            user: alice,
            operator: bob,
            approvalCount: 0,
            signature: sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: 0})
        });

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertTrue(approval.approvalCount == 0, "approvalCount");
        assertTrue(approval.nonce == 2, "nonce");
    }

    function testRevokeEIP712() public {
        address alice = address(eip1271Wallet);
        address bob = address(0xB0b);

        bytes32 digest = sigHelper.getPermitCancelClaimDigest({user: alice, operator: bob, approvalCount: 1});

        eip1271Wallet.sign(digest);

        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: 1, signature: bytes("")});

        vm.expectEmit(true, true, true, true);
        emit CancelClaimApproved(alice, bob, 0);

        digest = sigHelper.getPermitCancelClaimDigest({user: alice, operator: bob, approvalCount: 0});

        eip1271Wallet.sign(digest);

        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: 0, signature: bytes("")});

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertTrue(approval.approvalCount == 0, "approvalCount");
        assertTrue(approval.nonce == 2, "nonce");
    }

    function testPermitRegisteredContract() public {
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        BullaExtensionRegistry(bullaClaim.extensionRegistry()).setExtensionName(bob, "bobby bob");

        bullaClaim.permitCancelClaim({
            user: alice,
            operator: bob,
            approvalCount: 10,
            signature: sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: 10})
        });
    }

    /// @notice SPEC.SIG3
    function testCannotPermitWhenExtensionRegistryUnset() public {
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bytes memory signature =
            sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: 1});

        bullaClaim.setExtensionRegistry(address(0));

        // This call to the 0 address will fail
        vm.expectRevert();
        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: 1, signature: signature});
    }

    /// @notice SPEC.SIG1
    function testCannotUseCorruptSig() public {
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        bytes memory signature =
            sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: 1});
        signature[64] = bytes1(uint8(signature[64]) + 1);

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: 1, signature: signature});
    }

    /// @notice SPEC.SIG1
    function testCannotUseWrongSig() public {
        uint64 approvalCount = type(uint64).max;
        uint256 badGuyPK = uint256(0xBEEF);

        address alice = address(0xA11c3);
        address bob = address(0xB0b);

        // build a digest based on alice's approval
        bytes32 digest =
            sigHelper.getPermitCancelClaimDigest({user: alice, operator: bob, approvalCount: approvalCount});

        // sign the digest with the wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badGuyPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: approvalCount, signature: signature});
    }

    /// @notice SPEC.SIG1
    function testCannotReplaySig() public {
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);
        address bob = address(0xB0b);

        uint64 approvalCount = 1;

        bytes memory signature =
            sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: approvalCount});

        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: approvalCount, signature: signature});

        // alice then revokes her approval
        bullaClaim.permitCancelClaim({
            user: alice,
            operator: bob,
            approvalCount: 0,
            signature: sigHelper.signCancelClaimPermit({pk: alicePK, user: alice, operator: bob, approvalCount: 0})
        });

        // the initial signature can not be used to re-permit
        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCancelClaim({user: alice, operator: bob, approvalCount: approvalCount, signature: signature});
    }

    /// @notice SPEC.SIG2
    function testCannotPermitThe0Address() public {
        address user = address(0);
        address operator = vm.addr(0xBeefCafe);
        uint64 approvalCount = 1;

        bytes memory signature = sigHelper.signCancelClaimPermit({
            pk: uint256(12345),
            user: user,
            operator: operator,
            approvalCount: approvalCount
        });
        signature[64] = bytes1(uint8(signature[64]) + 11);
        // the above corrupt signature will return a 0 from ecrecover

        (uint8 v, bytes32 r, bytes32 s) = splitSig(signature);
        assertEq(
            ecrecover(sigHelper.getPermitCancelClaimDigest(user, operator, approvalCount), v, r, s),
            user,
            "ecrecover sanity check"
        );

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitCancelClaim({
            user: user,
            operator: operator,
            approvalCount: approvalCount,
            signature: signature
        });
    }

    /// @notice sanity check to ensure that existance of code at the operator address doesn't break anything
    function testCanPermitSmartContract() public {
        PenalizedClaim operator = new PenalizedClaim(address(bullaClaim));
        uint256 alicePK = uint256(0xA11c3);
        address alice = vm.addr(alicePK);

        bullaClaim.permitCancelClaim({
            user: alice,
            operator: address(operator),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: alicePK,
                user: alice,
                operator: address(operator),
                approvalCount: 1
            })
        });
    }

    function test_fuzz_permitAndRescindCreateClaimFrom(
        uint256 pk,
        uint256 operatorPK,
        uint64 approvalCount,
        bool registerContract
    ) public {
        vm.assume(pk != operatorPK);
        vm.assume(privateKeyValidity(pk) && privateKeyValidity(operatorPK));

        address user = vm.addr(pk);
        address operator = vm.addr(operatorPK);

        if (registerContract) {
            BullaExtensionRegistry(bullaClaim.extensionRegistry()).setExtensionName(operator, "BullaFake");
        }

        vm.expectEmit(true, true, true, true);
        emit CancelClaimApproved(user, operator, approvalCount);

        bytes memory signature =
            sigHelper.signCancelClaimPermit({pk: pk, user: user, operator: operator, approvalCount: approvalCount});

        bullaClaim.permitCancelClaim({
            user: user,
            operator: operator,
            approvalCount: approvalCount,
            signature: signature
        });

        (,,, CancelClaimApproval memory approval) = bullaClaim.approvals(user, operator);

        assertEq(approval.approvalCount, approvalCount, "approvalCount");
        assertEq(approval.nonce, 1, "nonce");
    }
}
