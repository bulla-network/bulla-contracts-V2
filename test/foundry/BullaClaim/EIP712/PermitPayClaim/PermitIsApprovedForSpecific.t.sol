// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "test/foundry/BullaClaim/EIP712/PermitPayClaim/Common.t.sol";
import "contracts/interfaces/IBullaClaim.sol";
import "contracts/libraries/BullaClaimPermitLib.sol";

/// @notice SPEC
/// permitPayClaim can approve a controller to pay _specific_ claims given the following conditions listed below as AS - (Approve Specific 1-5):
///     AS1: The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
///     AS2: `user` is not the 0 address -> otherwise: reverts
///     AS3: `approvalType` == PayClaimApprovalType.IsApprovedForSpecific
///     AS4: `approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
///     AS5: `paymentApprovals.length > 0` and contains valid `ClaimPaymentApprovals` -> otherwise: reverts
///     A valid ClaimPaymentApproval is defined as the following:
///         AS5.1: `ClaimPaymentApproval.claimId` is < type(uint88).max -> otherwise: reverts
///         AS5.2: `ClaimPaymentApproval.approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
///         AS5.3: `ClaimPaymentApproval.approvedAmount` < type(uint128).max -> otherwise: reverts
///   RESULT: The following call parameters are stored on on `user`'s approval of `controller`
///     AS.RES1: The approvalType = PayClaimApprovalType.IsApprovedForSpecific
///     AS.RES2: The approvalDeadline is stored if not 0
///     AS.RES3: The nonce is incremented by 1
///     AS.RES4. ClaimApprovals specified in calldata are stored and overwrite previous approvals
///     AS.RES5: A PayClaimApproval event is emitted
contract TestPermitPayClaim_IsApprovedForSpecific is PermitPayClaimTest {
    PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForSpecific;

    /// @notice happy path: SPEC.AS.RES1,2,3,4,5
    function testIsApprovedForSpecific() public {
        uint256 approvalDeadline = OCTOBER_23RD_2022;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](2);

        // create individual claim approvals
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});
        paymentApprovals[1] = ClaimPaymentApprovalParam({claimId: 2, approvedAmount: 98765, approvalDeadline: 25122});

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

        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, PayClaimApproval memory approval,,,,) = approvalRegistry.getApprovals(alice, bob);

        assertTrue(approval.approvalType == PayClaimApprovalType.IsApprovedForSpecific, "approvalType");
        assertEq(approval.approvalDeadline, approvalDeadline, "deadline");
        assertEq(approval.nonce, 1, "nonce");
        assertEq(approval.claimApprovals.length, 2, "claim approvals");

        for (uint256 i = 0; i < 2; i++) {
            assertEq(approval.claimApprovals[i].claimId, paymentApprovals[i].claimId, "claimId");
            assertEq(approval.claimApprovals[i].approvedAmount, paymentApprovals[i].approvedAmount, "approvedAmount");
            assertEq(
                approval.claimApprovals[i].approvalDeadline, paymentApprovals[i].approvalDeadline, "approvalDeadline"
            );
        }
    }

    function testIsApprovedForSpecificEIP1271() public {
        alice = address(eip1271Wallet);
        uint256 approvalDeadline = OCTOBER_23RD_2022;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](2);

        // create individual claim approvals
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});
        paymentApprovals[1] = ClaimPaymentApprovalParam({claimId: 2, approvedAmount: 98765, approvalDeadline: 25122});

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

        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: bytes("")
        });

        (, PayClaimApproval memory approval,,,,) = approvalRegistry.getApprovals(alice, bob);

        assertTrue(approval.approvalType == PayClaimApprovalType.IsApprovedForSpecific, "approvalType");
        assertEq(approval.approvalDeadline, approvalDeadline, "deadline");
        assertEq(approval.nonce, 1, "nonce");
        assertEq(approval.claimApprovals.length, 2, "claim approvals");

        for (uint256 i = 0; i < 2; i++) {
            assertEq(approval.claimApprovals[i].claimId, paymentApprovals[i].claimId, "claimId");
            assertEq(approval.claimApprovals[i].approvedAmount, paymentApprovals[i].approvedAmount, "approvedAmount");
            assertEq(
                approval.claimApprovals[i].approvalDeadline, paymentApprovals[i].approvalDeadline, "approvalDeadline"
            );
        }
    }

    /// @notice SPEC.AS1
    function testCannotSignForSomeoneElse() public {
        uint256 charliePK = uint256(0xC114c113);
        address user = alice;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        bytes32 digest = keccak256(
            bytes(
                BullaClaimPermitLib.getPermitPayClaimMessage(
                    approvalRegistry.controllerRegistry(), bob, approvalType, 0
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(charliePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(BaseBullaClaim.InvalidSignature.selector);
        approvalRegistry.permitPayClaim({
            user: user,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AS1
    function testCannotReplaySig() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        vm.expectRevert(BaseBullaClaim.InvalidSignature.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AS2
    function testCannotPermitThe0Address() public {
        address user = address(0);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        bytes32 digest = keccak256(
            bytes(
                BullaClaimPermitLib.getPermitPayClaimMessage(
                    approvalRegistry.controllerRegistry(), bob, approvalType, 0
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // corrupt the signature to get a 0 signer return from the ecrecover call
        signature[64] = bytes1(uint8(signature[64]) + 190);

        (v, r, s) = splitSig(signature);
        assertEq(ecrecover(digest, v, r, s), address(0), "ecrecover sanity check");

        vm.expectRevert(BaseBullaClaim.InvalidSignature.selector);
        approvalRegistry.permitPayClaim({
            user: user,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AS4
    function testCannotPermitWithTooLargeApprovalDeadline() public {
        uint256 approvalDeadline = uint256(type(uint40).max) + 1;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AS5
    function testCannotApproveForSpecificIfNoClaimsSpecified() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BaseBullaClaim.InvalidApproval.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA5.1
    function testCannotApproveForSpecificIfOneApprovalHasInvalidClaimId() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);

        paymentApprovals[2].claimId = uint256(type(uint88).max) + 1;

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BaseBullaClaim.InvalidApproval.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA5.2
    function testCannotApproveForSpecificIfTooLargeTimestamp() public {
        uint256 badApprovalDeadline = uint256(type(uint40).max) + 1;

        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);
        paymentApprovals[2].approvalDeadline = badApprovalDeadline;

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA5.2
    function testCannotApproveForSpecificIfInvalidTimestamp() public {
        uint256 badApprovalDeadline = OCTOBER_23RD_2022;
        vm.warp(OCTOBER_28TH_2022);

        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);
        paymentApprovals[2].approvalDeadline = badApprovalDeadline;

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA5.2
    function testCannotApproveForSpecificIfOneApprovalHasInvalidTimestamp() public {
        vm.warp(OCTOBER_28TH_2022); // set the block.timestamp to october 28th 2022

        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);
        paymentApprovals[2].approvalDeadline = OCTOBER_23RD_2022; // october 23rd - invalid deadline

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(IBullaClaim.ApprovalExpired.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AA5.3
    function testCannotApproveForSpecificIfOneApprovalHasInvalidApprovedAmount() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);
        paymentApprovals[2].approvedAmount = uint256(type(uint128).max) + 1;

        bytes memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(BaseBullaClaim.InvalidApproval.selector);
        approvalRegistry.permitPayClaim({
            user: alice,
            controller: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }
}
