// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

/// @notice SPEC:
/// A function can call this function to verify and "spend" `from`'s approval of `operator` to pay a claim under the following circumstances:
///     S1. The `approvalType` is not `Unapproved` -> otherwise: reverts
///     S2. The contract LockStatus is not `Locked` -> otherwise: reverts
///
///     When the `approvalType` is `IsApprovedForSpecific`, then `operator` must be approved to pay that claim meaning:
///         AS1: `from` has approved payment for the `claimId` parameter -> otherwise: reverts
///         AS2: `from` has approved payment for at least the `amount` parameter -> otherwise: reverts
///         AS3: `from`'s approval has not expired, meaning:
///             AS3.1: If the operator has an "operator" expirary, then the operator expirary must be greater than the current block timestamp -> otherwise: reverts
///             AS3.2: If the operator does not have an operator expirary and instead has a claim-specific expirary,
///                 then the claim-specific expirary must be greater than the current block timestamp -> otherwise: reverts
///
///         AS.RES1: If the `amount` parameter == the pre-approved amount on the permission, spend the permission -> otherwise: decrement the approved amount by `amount`
///
///     If the `approvalType` is `IsApprovedForAll`, then `operator` must be approved to pay, meaning:
///         AA1: `from`'s approval of `operator` has not expired -> otherwise: reverts
///
///         AA.RES1: This function allows execution to continue - (no storage needs to be updated)
contract TestPayClaimFrom is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;

    uint256 OCTOBER_28TH_2022 = 1666980688;
    uint256 OCTOBER_23RD_2022 = 1666560688;

    uint256 ownerPK = uint256(0xA11c3);
    address owner = vm.addr(ownerPK);
    address operator = address(0xb0b);
    address user2 = address(0x02);

    function setUp() public {
        weth = new WETH();

        vm.label(address(this), "TEST_CONTRACT");

        vm.label(owner, "OWNER");
        vm.label(operator, "OPERATOR");
        vm.label(user2, "USER2");

        (bullaClaim,) = (new Deployer()).deploy_test(address(this), address(0xFEE), LockState.Unlocked, 0);
        sigHelper = new EIP712Helper(address(bullaClaim));

        weth.transferFrom(address(this), owner, 1000 ether);
        weth.transferFrom(address(this), operator, 1000 ether);
        weth.transferFrom(address(this), user2, 1000 ether);
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

    function _generateClaimPaymentApprovals(uint8 count) internal returns (ClaimPaymentApprovalParam[] memory) {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 claimId = _newClaim({_creditor: user2, _debtor: operator});
            paymentApprovals[i] =
                ClaimPaymentApprovalParam({claimId: claimId, approvedAmount: 1 ether, approvalDeadline: 0});
        }
        return paymentApprovals;
    }

    function _permitPayClaim(
        uint256 _ownerPK,
        address _operator,
        PayClaimApprovalType _approvalType,
        uint256 _approvalDeadline,
        ClaimPaymentApprovalParam[] memory _paymentApprovals
    ) private {
        Signature memory sig = sigHelper.signPayClaimPermit(
            _ownerPK, vm.addr(_ownerPK), _operator, _approvalType, _approvalDeadline, _paymentApprovals
        );
        bullaClaim.permitPayClaim(
            vm.addr(_ownerPK), _operator, _approvalType, _approvalDeadline, _paymentApprovals, sig
        );
    }

    function _permitPayClaim(uint256 _ownerPK, address _operator, uint256 _approvalDeadline) private {
        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](0);
        _permitPayClaim(_ownerPK, _operator, PayClaimApprovalType.IsApprovedForAll, _approvalDeadline, approvals);
    }

    ///////// PAY CLAIM FROM TESTS /////////
    //// APPROVED FOR SPECIFIC ////

    /// @notice SPEC.AS.RES1
    function testApprovedForSpecificFullPayment() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});
        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](1);
        approvals[0] = ClaimPaymentApprovalParam({claimId: claimId, approvedAmount: 1 ether, approvalDeadline: 0});

        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: 0,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);

        (, PayClaimApproval memory approval) = bullaClaim.approvals(owner, operator);
        assertEq(approval.claimApprovals.length, 0, "AS.RES1: claim approvals not cleared");
    }

    /// @notice SPEC.AS.RES1
    function testApprovedForSpecificPartialPayment() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});
        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](1);
        approvals[0] = ClaimPaymentApprovalParam({claimId: claimId, approvedAmount: 1 ether, approvalDeadline: 0});

        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: 0,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.prank(owner);
        weth.approve(address(bullaClaim), 0.5 ether);

        vm.prank(operator);
        bullaClaim.payClaimFrom(owner, claimId, 0.5 ether);

        (, PayClaimApproval memory approval) = bullaClaim.approvals(owner, operator);
        assertEq(approval.claimApprovals.length, 1, "AS.RES1: claim approval not decremented");
        assertEq(approval.claimApprovals[0].approvedAmount, 0.5 ether, "AS.RES1: claim approval not decremented");
        assertEq(
            approval.claimApprovals[0].approvalDeadline, approvals[0].approvalDeadline, "approval deadline changed"
        );
    }

    /// @notice SPEC.AS.RES1
    function testApprovedForSpecificWithManyApprovals(uint8 approvalCount, uint8 claimIdToPay) public {
        vm.assume(approvalCount > 1 && claimIdToPay > 0);
        vm.assume(claimIdToPay < approvalCount);

        ClaimPaymentApprovalParam[] memory approvals = _generateClaimPaymentApprovals(approvalCount);

        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: 0,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        bullaClaim.payClaimFrom(owner, claimIdToPay, 1 ether);

        (, PayClaimApproval memory approval) = bullaClaim.approvals(owner, operator);
        assertEq(approval.claimApprovals.length, approvalCount - 1, "AS.RES1: claim approvals not cleared");

        bool approvalFound;
        for (uint256 i; i < approval.claimApprovals.length; i++) {
            if (approval.claimApprovals[i].claimId == claimIdToPay) approvalFound = true;
        }
        assertFalse(approvalFound, "AS.RES1: claim approval not cleared");
    }

    /// @notice SPEC.S1
    function testCannotPayClaimFromIfUnapproved() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        // user 2 tries to pull owner's funds
        vm.prank(user2);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    /// @notice SPEC.AS1
    function testCannotPayWhenClaimHasNotBeenSpecified() public {
        _newClaim({_creditor: user2, _debtor: owner});
        _newClaim({_creditor: user2, _debtor: owner});

        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](1);
        approvals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 1 ether, approvalDeadline: 0});

        // operator has been approved to pay claimId 1, but not claimId 2
        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: 0,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        // operator tries to pay claimId 2
        vm.prank(operator);
        vm.expectRevert(BullaClaim.NotApproved.selector);
        bullaClaim.payClaimFrom(owner, 2, 1 ether);
    }

    /// @notice SPEC.AS2
    function testCannotPayWhenSpecificClaimIsUnderApproved() public {
        _newClaim({_creditor: user2, _debtor: owner});

        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](1);
        approvals[0] = ClaimPaymentApprovalParam({claimId: 1, approvedAmount: 0.5 ether, approvalDeadline: 0});

        // operator has been approved to pay .5 ether
        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: 0,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        // operator tries to pay 1 ether
        vm.prank(operator);
        vm.expectRevert(BullaClaim.PaymentUnderApproved.selector);
        bullaClaim.payClaimFrom(owner, 1, 1 ether);
    }

    /// @notice SPEC.AS3.1
    function testCannotPayWhenApprovedForSpecificAndOperatorApprovalHasExpired() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});

        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](1);
        // this is an unexpiring approval
        approvals[0] = ClaimPaymentApprovalParam({claimId: claimId, approvedAmount: 1 ether, approvalDeadline: 0});

        // operator can only pay claims for owner until the 23rd
        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: OCTOBER_23RD_2022,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.warp(OCTOBER_28TH_2022);

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        // operator tries to pay 1 ether on October 28th
        vm.prank(operator);
        vm.expectRevert(BullaClaim.PastApprovalDeadline.selector);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    /// @notice SPEC.AS3.2
    function testCannotPayWhenApprovedForSpecificAndClaimApprovalHasExpired() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});

        ClaimPaymentApprovalParam[] memory approvals = new ClaimPaymentApprovalParam[](1);
        // approval for claimId 1 expires on the 23rd
        approvals[0] =
            ClaimPaymentApprovalParam({claimId: claimId, approvedAmount: 1 ether, approvalDeadline: OCTOBER_23RD_2022});

        // operator has unexpiring approval to pay claims for owner
        _permitPayClaim({
            _ownerPK: ownerPK,
            _operator: operator,
            _approvalDeadline: 0,
            _approvalType: PayClaimApprovalType.IsApprovedForSpecific,
            _paymentApprovals: approvals
        });

        vm.warp(OCTOBER_28TH_2022);

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        // operator tries to pay 1 ether on October 28th
        vm.prank(operator);
        vm.expectRevert(BullaClaim.PastApprovalDeadline.selector);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    //// APPROVED FOR ALL ////
    /// @notice happy path : SPEC.AA.RES1
    function testIsApprovedForAll() public {
        _permitPayClaim({_ownerPK: ownerPK, _operator: operator, _approvalDeadline: 0});
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    /// @notice SPEC.AA1
    function testCannotPayWhenApprovedForAllAndOperatorApprovalExpired() public {
        _permitPayClaim({_ownerPK: ownerPK, _operator: operator, _approvalDeadline: OCTOBER_23RD_2022});
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});

        vm.warp(OCTOBER_28TH_2022);

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        vm.expectRevert(BullaClaim.PastApprovalDeadline.selector);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    //// CONTRACT LOCK ////
    /// @notice SPEC.S2
    function testCanPayClaimFromWhenPartiallyLocked() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});
        _permitPayClaim({_ownerPK: ownerPK, _operator: operator, _approvalDeadline: 0});

        bullaClaim.setLockState(LockState.NoNewClaims);

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    /// @notice SPEC.S2
    function testCannotPayClaimFromWhenLocked() public {
        uint256 claimId = _newClaim({_creditor: user2, _debtor: owner});
        _permitPayClaim({_ownerPK: ownerPK, _operator: operator, _approvalDeadline: 0});

        bullaClaim.setLockState(LockState.Locked);

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        vm.expectRevert(BullaClaim.Locked.selector);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }

    /// a strange side effect of using the native token is that operator must send the ether value in the call
    function testPayClaimFromWithNativeToken() public {
        vm.deal(operator, 1 ether);

        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: user2,
                debtor: owner,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0), // native token
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );

        _permitPayClaim({_ownerPK: ownerPK, _operator: operator, _approvalDeadline: 0});

        vm.prank(operator);
        bullaClaim.payClaimFrom{value: 1 ether}(owner, claimId, 1 ether);
    }
}
