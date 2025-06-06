// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "test/foundry/BullaClaim/EIP712/PermitPayClaim/Common.t.sol";
import "contracts/interfaces/IBullaClaim.sol";

/// @notice SPEC
/// permitPayClaim() can approve a controller to pay _all_ claims given the following conditions listed below as AA - (Approve All 1-5):
///     AA1: The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
///     AA2: `user` is not the 0 address -> otherwise: reverts
///     AA3: `approvalType` == PayClaimApprovalType.IsApprovedForAll
///     AA4: `approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
///     AA5: `paymentApprovals.length == 0` -> otherwise: reverts
///   RESULT: The following call arguments are stored on on `user`'s approval of `controller`
///     AA.RES1: The approvalType = PayClaimApprovalType.IsApprovedForAll
///     AA.RES2: The nonce is incremented by 1
///     AA.RES3: If the previous approvalType == PayClaimApprovalType.IsApprovedForSpecific, delete the claimApprovals array -> otherwise: continue
///     AA.RES4: A PayClaimApproval event is emitted
contract TestPermitPayClaim_IsApprovedForAll is PermitPayClaimTest {
    PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForAll;

    /// @notice happy path: SPEC.AA.RES1,2,4
    function testPermitApprovedForAll(uint256 approvalDeadline) public {
        vm.assume(approvalDeadline < type(uint40).max);

        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, approvalType, approvalDeadline, paymentApprovals);

        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(alice, bob);

        // SPEC.AA.RES1-4
        assertTrue(approval.approvalType == PayClaimApprovalType.IsApprovedForAll, "approvalType");
        assertEq(approval.approvalDeadline, approvalDeadline, "approvalDeadline");
        assertTrue(approval.claimApprovals.length == 0, "specific approvals");
        assertTrue(approval.nonce == 1, "nonce");
    }

    function testPermitApprovedForAllEIP1271(uint256 approvalDeadline) public {
        alice = address(eip1271Wallet);
        vm.assume(approvalDeadline < type(uint40).max);

        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes32 digest = sigHelper.getPermitPayClaimDigest({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });
        eip1271Wallet.sign(digest);

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, approvalType, approvalDeadline, paymentApprovals);

        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: bytes("")
        });

        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(alice, bob);

        // SPEC.AA.RES1-4
        assertTrue(approval.approvalType == PayClaimApprovalType.IsApprovedForAll, "approvalType");
        assertEq(approval.approvalDeadline, approvalDeadline, "approvalDeadline");
        assertTrue(approval.claimApprovals.length == 0, "specific approvals");
        assertTrue(approval.nonce == 1, "nonce");
    }

    /// @notice SPEC.AA2
    function testCannotSignForSomeoneElse() public {
        uint256 charliePK = uint256(0xC114c113);
        address user = alice;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: charliePK, // charlie signs an approval for alice
            user: user,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            user: user,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA2
    function testCannotReplaySig() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK, // charlie signs an approval for alice
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA2
    function testCannotPermitThe0Address() public {
        address user = address(0);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes32 digest = keccak256(
            bytes(BullaClaimPermitLib.getPermitPayClaimMessage(bullaClaim.controllerRegistry(), bob, approvalType, 0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // corrupt the signature to get a 0 signer return from the ecrecover call
        signature[64] = bytes1(uint8(signature[64]) + 190);

        (v, r, s) = splitSig(signature);
        assertEq(ecrecover(digest, v, r, s), address(0), "ecrecover sanity check");

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            user: user,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA4
    function testCannotApproveForAllIfApprovalDeadlineInvalid() public {
        vm.warp(OCTOBER_28TH_2022); // set the block.timestamp to october 28th 2022
        uint256 approvalDeadline = OCTOBER_23RD_2022;

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: new ClaimPaymentApprovalParam[](0)
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: signature
        });

        uint256 tooBigDeadline = uint256(type(uint40).max) + 1;

        // deadline > type(uint40).max
        signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: tooBigDeadline,
            paymentApprovals: new ClaimPaymentApprovalParam[](0)
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: tooBigDeadline,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: signature
        });
    }

    /// @notice SPEC.AA4
    function testCannotApproveForAllIfApprovalDeadlineTooLarge() public {
        uint256 tooBigDeadline = uint256(type(uint40).max) + 1;

        // deadline > type(uint40).max
        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: tooBigDeadline,
            paymentApprovals: new ClaimPaymentApprovalParam[](0)
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: tooBigDeadline,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: signature
        });
    }

    /// @notice SPEC.AA5
    function testCannotApprovedForAllIfSpecificApprovalsSpecified() public {
        uint256 approvalDeadline = 0;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 1 ether, approvalDeadline: 0});

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BullaClaim.InvalidApproval.selector);
        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA.RES3
    function testChangingToApprovedForAllDeletesSpecificApprovals(uint8 approvalsCount) public {
        vm.assume(approvalsCount > 0);

        approvalType = PayClaimApprovalType.IsApprovedForSpecific;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](approvalsCount);

        // create individual claim approvals
        for (uint256 i = 0; i < approvalsCount; i++) {
            paymentApprovals[i] =
                ClaimPaymentApprovalParam({claimId: i, approvedAmount: 143 * i + 1, approvalDeadline: i * 100});
        }

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(alice, bob);

        assertEq(approval.approvalDeadline, 0, "approvalDeadline");
        assertEq(approval.claimApprovals.length, approvalsCount, "specific approvals");

        PayClaimApprovalType newApprovalType = PayClaimApprovalType.IsApprovedForAll;
        paymentApprovals = new ClaimPaymentApprovalParam[](0);

        signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: newApprovalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        bullaClaim.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: newApprovalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, approval,,,,) = bullaClaim.approvals(alice, bob);

        assertEq(approval.claimApprovals.length, 0, "specific approvals");
        assertEq(approval.approvalDeadline, 0, "approvalDeadline");
        assertEq(approval.nonce, 2, "nonce");
    }
}
