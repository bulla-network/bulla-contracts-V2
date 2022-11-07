// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "test/foundry/BullaClaim/EIP712/PermitPayClaim/Common.t.sol";

/// @notice SPEC
/// permitPayClaim() can _revoke_ an operator to pay claims given the following conditions listed below as AR - (Approval Revoked 1-5):
///     AR1: The recovered signer from the EIP712 signature == `owner` -> otherwise: reverts
///     AR2: `owner` is not the 0 address -> otherwise: reverts
///     AR3: `approvalType` == PayClaimApprovalType.Unapproved
///     AR4: `approvalDeadline` == 0 -> otherwise: reverts
///     AR5: `paymentApprovals.length` == 0 -> otherwise: reverts
///   RESULT: `owner`'s approval of `operator` is updated to the following:
///     AR.RES1: approvalType is deleted (equivalent to being set to `Unapproved`)
///     AR.RES2: approvalDeadline is deleted
///     AR.RES3: The nonce is incremented by 1
///     AR.RES4: The claimApprovals array is deleted
///     AR.RES5: A PayClaimApproval event is emitted

contract TestPermitPayClaim_Unapproved is PermitPayClaimTest {
    PayClaimApprovalType approvalType = PayClaimApprovalType.Unapproved;

    /// @dev create an approval for bob to pay claims on alice's behalf
    function _setUp(PayClaimApprovalType _approvalType) internal {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);
        if (_approvalType == PayClaimApprovalType.IsApprovedForSpecific) {
            paymentApprovals = _generateClaimPaymentApprovals(4);
        }

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: _approvalType,
            approvalDeadline: 12455,
            paymentApprovals: paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: _approvalType,
                approvalDeadline: 12455,
                paymentApprovals: paymentApprovals
            })
        });
    }

    /// @notice happy path: AR.RES1,2,3,5
    function testRevoke() public {
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, PayClaimApprovalType.Unapproved, 0, new ClaimPaymentApprovalParam[](0));

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, PayClaimApproval memory approval,,) = bullaClaim.approvals(alice, bob);
        assertTrue(approval.approvalType == approvalType, "approvalType");
        assertEq(approval.approvalDeadline, 0, "deadline");
        assertEq(approval.nonce, 2, "nonce");
        assertEq(approval.claimApprovals.length, 0, "claim approvals");
    }

    /// @notice SPEC.AR.RES4
    function testRevokeDeleteSpecificApprovals() public {
        _setUp(PayClaimApprovalType.IsApprovedForSpecific);

        (, PayClaimApproval memory approval,,) = bullaClaim.approvals(alice, bob);
        assertEq(approval.claimApprovals.length, 4, "claim approvals");

        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalDeadline: 0,
                paymentApprovals: paymentApprovals
            })
        });

        (, approval,,) = bullaClaim.approvals(alice, bob);
        assertEq(approval.claimApprovals.length, 0, "claim approvals");
    }

    /// @notice SPEC.AR1
    function testCannotSignForSomeoneElse() public {
        _setUp(PayClaimApprovalType.IsApprovedForAll);
        uint256 charliePK = uint256(keccak256(bytes("charlie")));

        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: charliePK, // charlie signs an approval for alice
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            owner: alice,
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

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AR2
    function testCannotSignForThe0Address() public {
        address owner = address(0);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes32 digest = keccak256(
            bytes(BullaClaimEIP712.getPermitPayClaimMessage(bullaClaim.extensionRegistry(), bob, approvalType, 0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        Signature memory signature = Signature({v: v, r: r, s: s});

        // corrupt the signature to get a 0 signer return from the ecrecover call
        signature.r = bytes32(uint256(signature.v) + 10);

        assertEq(ecrecover(digest, signature.v, signature.r, signature.s), address(0), "ecrecover sanity check");

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            owner: owner,
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

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidPaymentApproval.selector);
        bullaClaim.permitPayClaim({
            owner: alice,
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

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidPaymentApproval.selector);
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }
}
