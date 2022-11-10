// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "test/foundry/BullaClaim/EIP712/PermitPayClaim/Common.t.sol";

/// @notice SPEC
/// permitPayClaim can approve an operator to pay _specific_ claims given the following conditions listed below as AS - (Approve Specific 1-5):
///     AS1: The recovered signer from the EIP712 signature == `owner` -> otherwise: reverts
///     AS2: `owner` is not the 0 address -> otherwise: reverts
///     AS3: `approvalType` == PayClaimApprovalType.IsApprovedForSpecific
///     AS4: `approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
///     AS5: `paymentApprovals.length > 0` and contains valid `ClaimPaymentApprovals` -> otherwise: reverts
///     A valid ClaimPaymentApproval is defined as the following:
///         AS5.1: `ClaimPaymentApproval.claimId` is < type(uint88).max -> otherwise: reverts
///         AS5.2: `ClaimPaymentApproval.approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
///         AS5.3: `ClaimPaymentApproval.approvedAmount` < type(uint128).max -> otherwise: reverts
///   RESULT: The following call parameters are stored on on `owner`'s approval of `operator`
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

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, approvalType, approvalDeadline, paymentApprovals);

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, PayClaimApproval memory approval,,) = bullaClaim.approvals(alice, bob);

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
        address owner = alice;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        bytes32 digest = keccak256(
            bytes(BullaClaimEIP712.getPermitPayClaimMessage(bullaClaim.extensionRegistry(), bob, approvalType, 0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(charliePK, digest);
        Signature memory signature = Signature({v: v, r: r, s: s});

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

    /// @notice SPEC.AS1
    function testCannotReplaySig() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

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

    /// @notice SPEC.AS2
    function testCannotPermitThe0Address() public {
        address owner = address(0);
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        bytes32 digest = keccak256(
            bytes(BullaClaimEIP712.getPermitPayClaimMessage(bullaClaim.extensionRegistry(), bob, approvalType, 0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        Signature memory signature = Signature({v: v, r: r, s: s});

        // corrupt the signature to get a 0 signer return from the ecrecover call
        signature.r = bytes32(uint256(signature.v) + 190);

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

    /// @notice SPEC.AS4
    function testCannotPermitWithTooLargeApprovalDeadline() public {
        uint256 approvalDeadline = uint256(type(uint40).max) + 1;
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](1);
        paymentApprovals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 12345, approvalDeadline: 0});

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.InvalidTimestamp.selector, approvalDeadline));
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    /// @notice SPEC.AS5
    function testCannotApproveForSpecificIfNoClaimsSpecified() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](0);

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

    /// @notice SPEC.AA5.1
    function testCannotApproveForSpecificIfOneApprovalHasInvalidClaimId() public {
        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);

        paymentApprovals[2].claimId = uint256(type(uint88).max) + 1;

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

    /// @notice SPEC.AA5.2
    function testCannotApproveForSpecificIfTooLargeTimestamp() public {
        uint256 badApprovalDeadline = uint256(type(uint40).max) + 1;

        ClaimPaymentApprovalParam[] memory paymentApprovals = _generateClaimPaymentApprovals(4);
        paymentApprovals[2].approvalDeadline = badApprovalDeadline;

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.InvalidTimestamp.selector, badApprovalDeadline));
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
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

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.InvalidTimestamp.selector, badApprovalDeadline));
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
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

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.InvalidTimestamp.selector, OCTOBER_23RD_2022));
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
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
