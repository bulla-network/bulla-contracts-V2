// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "test/foundry/BullaClaim/EIP712/PermitPayClaim/Common.t.sol";

/// @notice SPEC
/// permitPayClaim() can _revoke_ an operator to pay claims given the following conditions listed below as AR - (Approval Revoked 1-5):
///     AR1: The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
///     AR2: `user` is not the 0 address -> otherwise: reverts
///     AR3: `approvalType` == PayClaimApprovalType.Unapproved
///     AR4: `approvalDeadline` == 0 -> otherwise: reverts
///     AR5: `paymentApprovals.length` == 0 -> otherwise: reverts
///   RESULT: `user`'s approval of `operator` is updated to the following:
///     AR.RES1: approvalType is deleted (equivalent to being set to `Unapproved`)
///     AR.RES2: approvalDeadline is deleted
///     AR.RES3: The nonce is incremented by 1
///     AR.RES4: The claimApprovals array is deleted
///     AR.RES5: A PayClaimApproval event is emitted
contract TestPermitPayClaim_Unapproved is PermitPayClaimTest {
    PayClaimApprovalType approvalType = PayClaimApprovalType.Unapproved;

    /// @dev create an approval for bob to pay claims on alice's behalf
    function _init(PayClaimApprovalType _approvalType, bool useSmartContractWallet) internal {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);
        if (_approvalType == PayClaimApprovalType.IsApprovedForSpecific) {
            paymentApprovals = _generateClaimPaymentApprovals(4);
        }

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: _approvalType,
            approvalDeadline: 12455,
            paymentApprovals: paymentApprovals
        });

        if (useSmartContractWallet) {
            alice = address(eip1271Wallet);
            signature = bytes("");
            bytes32 digest = sigHelper.getPermitPayClaimDigest(alice, bob, _approvalType, 12455, paymentApprovals);
            eip1271Wallet.sign(digest);
        }

        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: _approvalType,
            approvalDeadline: 12455,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    function _setUp(PayClaimApprovalType _approvalType) internal {
        _init(_approvalType, false);
    }

    function _setUpWithSmartContractWallet(PayClaimApprovalType _approvalType) internal {
        _init(_approvalType, true);
    }

    /// @notice happy path: AR.RES1,2,3,5
    function testRevoke() public {
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, PayClaimApprovalType.Unapproved, 0, new ClaimPaymentApprovalParam[](0));

        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(alice, bob);
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertEq(approval.approvalDeadline, 0, "deadline");
        assertEq(approval.nonce, 2, "nonce");
        assertEq(approval.claimApprovals.length, 0, "claim approvals");
    }

    function testRevokeEIP1271() public {
        _setUpWithSmartContractWallet(PayClaimApprovalType.IsApprovedForAll);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes32 digest = sigHelper.getPermitPayClaimDigest(alice, bob, approvalType, 0, paymentApprovals);
        eip1271Wallet.sign(digest);

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, PayClaimApprovalType.Unapproved, 0, new ClaimPaymentApprovalParam[](0));

        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: bytes("")
        });

        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(alice, bob);
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertEq(approval.approvalDeadline, 0, "deadline");
        assertEq(approval.nonce, 2, "nonce");
        assertEq(approval.claimApprovals.length, 0, "claim approvals");
    }

    /// @notice SPEC.AR.RES4
    function testRevokeDeleteSpecificApprovals() public {
        _setUp(PayClaimApprovalType.IsApprovedForSpecific);

        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(alice, bob);
        assertEq(approval.claimApprovals.length, 4, "claim approvals");

        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: alicePK,
                user: alice,
                operator: bob,
                approvalType: approvalType,
                approvalDeadline: 0,
                paymentApprovals: paymentApprovals
            })
        });

        (, approval,,,,) = bullaClaim.approvals(alice, bob);
        assertEq(approval.claimApprovals.length, 0, "claim approvals");
    }

    /// @notice SPEC.AR1
    function testCannotSignForSomeoneElse() public {
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        uint256 charliePK = uint256(keccak256(bytes("charlie")));

        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: charliePK, // charlie signs an approval for alice
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AR1
    function testCannotReplaySig() public {
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AR2
    function testCannotSignForThe0Address() public {
        address user = address(0);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes32 digest = keccak256(
            bytes(BullaClaimPermitLib.getPermitPayClaimMessage(bullaClaim.extensionRegistry(), bob, approvalType, 0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // corrupt the signature to get a 0 signer return from the ecrecover call
        signature[64] = bytes1(uint8(signature[64]) + 10);

        (v, r, s) = splitSig(signature);
        assertEq(ecrecover(digest, v, r, s), address(0), "ecrecover sanity check");

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            user: user,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AR4
    function testCannotSpecifyApprovalDeadline() public {
        uint256 approvalDeadline = OCTOBER_28TH_2022;
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AR5
    function testCannotSpecifySpecificPaymentApprovals() public {
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 1 ether, approvalDeadline: 0});

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }
}
