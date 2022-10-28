// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import "contracts/BullaClaim.sol";
import "contracts/mocks/PenalizedClaim.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/// @title Test the permitPayClaim function
contract TestPermitPayClaim is Test {
    BullaClaim internal bullaClaim;
    WETH internal weth;
    EIP712Helper internal sigHelper;

    uint256 alicePK = uint256(0xA11c3);
    address alice = vm.addr(alicePK);
    address bob = address(0xB0b);

    event PayClaimApproved(
        address indexed owner,
        address indexed operator,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApproval[] paymentApprovals
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

    function _newClaim(address _creditor, address _debtor) private returns (uint256 claimId) {
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );
    }

    //// TEST IS APPROVED FOR ALL ////

    function testPermitApprovedForAll(uint40 approvalDeadline) public {
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForAll;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](0);

        vm.expectEmit(true, true, true, true);
        emit PayClaimApproved(alice, bob, approvalType, approvalDeadline, paymentApprovals);

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalDeadline: approvalDeadline,
                paymentApprovals: paymentApprovals
            })
        });

        (, PayClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertEq(approval.approvalDeadline, approvalDeadline, "approvalDeadline");
        assertTrue(approval.claimApprovals.length == 0, "specific approvals");
        assertTrue(approval.nonce == 1, "nonce");
    }

    function testCannotApprovedForAllIfSpecificApprovalsSpecified() public {
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForAll;
        uint40 approvalDeadline = 0;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](1);
        paymentApprovals[0] = ClaimPaymentApproval({claimId: 1, approvedAmount: type(uint128).max, approvalDeadline: 0});

        _newClaim({_creditor: alice, _debtor: bob});

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

    function testCannotApproveForAllIfApprovalDeadlineInvalid() public {
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForAll;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](0);

        vm.warp(1666980688); // set the block.timestamp to october 28th 2022
        uint40 approvalDeadline = 1666560688; // october 23rd - invalid deadline

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

    function testChangingApprovalDeletesSpecificApprovals(uint8 approvalsCount) public {
        vm.assume(approvalsCount > 0);

        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForSpecific;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](
                approvalsCount
            );

        // create individual claim approvals
        for (uint256 i = 0; i < approvalsCount; i++) {
            uint256 claimId = _newClaim({_creditor: alice, _debtor: bob});
            paymentApprovals[i] = ClaimPaymentApproval({
                claimId: uint88(claimId),
                approvedAmount: uint128(143 * i + 1),
                approvalDeadline: uint40(i * 100)
            });
        }

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

        (, PayClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertEq(approval.approvalDeadline, 0, "approvalDeadline");
        assertEq(approval.claimApprovals.length, approvalsCount, "specific approvals");

        // randomly change the approval type
        PayClaimApprovalType newApprovalType =
            approvalsCount % 2 == 0 ? PayClaimApprovalType.IsApprovedForAll : PayClaimApprovalType.Unapproved;

        paymentApprovals = new ClaimPaymentApproval[](0);

        signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: newApprovalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: newApprovalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });

        (, approval) = bullaClaim.approvals(alice, bob);

        assertEq(approval.claimApprovals.length, 0, "specific approvals");
        assertEq(approval.approvalDeadline, 0, "approvalDeadline");
        assertEq(approval.nonce, 2, "nonce");
    }

    function testCannotApproveThe0Address() public {
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForAll;
        uint40 approvalDeadline = 1666560688; // october 23rd 2022
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](0);

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: address(0),
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals
        });

        // corrupt the signature to get a 0 signer return from the ecrecover call
        signature.r = bytes32(uint256(signature.r) + 1);

        vm.expectRevert(BullaClaim.InvalidSignature.selector);
        bullaClaim.permitPayClaim({
            owner: address(0),
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    //// TEST IS APPROVED FOR SPECIFIC ////

    function testIsApprovedForSpecific() public {
        uint40 approvalDeadline = 1666560688;
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForSpecific;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](2);

        _newClaim({_creditor: alice, _debtor: bob});
        _newClaim({_creditor: alice, _debtor: bob});
        // create individual claim approvals

        paymentApprovals[0] = ClaimPaymentApproval({claimId: uint88(1), approvedAmount: 12345, approvalDeadline: 0});
        paymentApprovals[1] = ClaimPaymentApproval({claimId: uint88(2), approvedAmount: 98765, approvalDeadline: 25122});

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: approvalDeadline,
            paymentApprovals: paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalDeadline: approvalDeadline,
                paymentApprovals: paymentApprovals
            })
        });

        (, PayClaimApproval memory approval) = bullaClaim.approvals(alice, bob);

        assertEq(approval.approvalDeadline, approvalDeadline, "deadline");
        assertEq(approval.claimApprovals.length, 2, "claim approvals");
        for (uint256 i = 0; i < 2; i++) {
            assertEq(approval.claimApprovals[i].claimId, paymentApprovals[i].claimId, "claimId");
            assertEq(approval.claimApprovals[i].approvedAmount, paymentApprovals[i].approvedAmount, "approvedAmount");
            assertEq(
                approval.claimApprovals[i].approvalDeadline, paymentApprovals[i].approvalDeadline, "approvalDeadline"
            );
        }
    }

    function testCannotApproveForSpecificIfNoClaimSpecified() public {
        uint40 approvalDeadline = 1666560688;
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForSpecific;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](0);

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

    function testCannotApproveForSpecificIfClaimIsNotMintedYet() public {
        uint40 approvalDeadline = 1666560688;
        uint256 currentClaimId = bullaClaim.currentClaimId();
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForSpecific;

        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](1);
        paymentApprovals[0] =
            ClaimPaymentApproval({claimId: uint88(currentClaimId + 1), approvedAmount: 222441224, approvalDeadline: 0});

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

    function testCannotApproveForSpecificIfOneApprovalHasInvalidTimestamp(uint8 approvalsCount) public {
        vm.assume(approvalsCount > 0);

        vm.warp(1666980688); // set the block.timestamp to october 28th 2022

        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForSpecific;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](
                approvalsCount
            );

        for (uint256 i = 0; i < approvalsCount; i++) {
            uint256 claimId = _newClaim({_creditor: alice, _debtor: bob});
            paymentApprovals[i] = ClaimPaymentApproval({
                claimId: uint88(claimId),
                approvedAmount: uint128(143 * i + 1),
                approvalDeadline: 0
            });
        }

        paymentApprovals[approvalsCount - 1].approvalDeadline = 1666560688; // october 23rd - invalid deadline

        Signature memory signature = sigHelper.signPayClaimPermit({
            pk: alicePK,
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.InvalidTimestamp.selector, 1666560688));
        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 0,
            paymentApprovals: paymentApprovals,
            signature: signature
        });
    }

    function testRevoke() public {
        PayClaimApprovalType approvalType = PayClaimApprovalType.IsApprovedForAll;
        ClaimPaymentApproval[] memory paymentApprovals = new ClaimPaymentApproval[](0);

        bullaClaim.permitPayClaim({
            owner: alice,
            operator: bob,
            approvalType: approvalType,
            approvalDeadline: 12455,
            paymentApprovals: paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: alicePK,
                owner: alice,
                operator: bob,
                approvalType: approvalType,
                approvalDeadline: 12455,
                paymentApprovals: paymentApprovals
            })
        });

        approvalType = PayClaimApprovalType.Unapproved;

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
        (, PayClaimApproval memory approval) = bullaClaim.approvals(alice, bob);
        assertEq(uint8(approval.approvalType), uint8(approvalType), "approvalType");
        assertEq(approval.approvalDeadline, 0, "deadline");
        assertEq(approval.nonce, 2, "nonce");
        assertEq(approval.claimApprovals.length, 0, "claim approvals");
    }
}
