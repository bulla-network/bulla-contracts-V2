//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestPenalizedClaim is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    PenalizedClaim public penalizedClaim;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address feeReceiver = address(0xFee);

    function setUp() public {
        weth = new WETH();

        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
        penalizedClaim = new PenalizedClaim(address(bullaClaim));

        vm.deal(debtor, 10 ether);
    }

    // deploy contracts, setup extension, ensure cannot call create, cancel, or pay directly on BullaClaim
    function testFeeWorks() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(penalizedClaim),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(penalizedClaim),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.prank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(penalizedClaim),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.BindingPending
            })
        );

        bullaClaim.permitUpdateBinding({
            user: debtor,
            operator: address(penalizedClaim),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(penalizedClaim),
                approvalCount: 1
            })
        });

        vm.prank(debtor);
        penalizedClaim.acceptClaim(claimId);

        vm.warp(block.timestamp + 2 days);

        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(penalizedClaim),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(penalizedClaim),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        vm.prank(debtor);
        penalizedClaim.payClaim{value: 1.05 ether}(claimId, 1.05 ether);

        assertTrue(bullaClaim.getClaim(claimId).status == Status.Paid);
    }

    function testCannotBypassDelegator() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(penalizedClaim),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(penalizedClaim),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.prank(creditor);
        uint256 claimId = penalizedClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(penalizedClaim),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.BindingPending
            })
        );

        vm.startPrank(debtor);

        vm.expectRevert(BullaClaim.ClaimDelegated.selector);
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        vm.expectRevert(BullaClaim.ClaimDelegated.selector);
        bullaClaim.payClaim{value: 0.5 ether}(claimId, 0.5 ether);

        vm.expectRevert(BullaClaim.ClaimDelegated.selector);
        bullaClaim.cancelClaim(claimId, "Nahhhh");
    }
}
