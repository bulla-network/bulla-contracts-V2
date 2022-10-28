// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Deployer} from "script/Deployment.s.sol";

contract PayClaimFrom is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaFeeCalculator public feeCalculator;

    uint256 creditorPK = uint256(0x01);

    address creditor = vm.addr(creditorPK);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    uint256 ownerPK = uint256(0xA11c3);
    address owner = vm.addr(ownerPK);
    address operator = address(0xb0b);

    function setUp() public {
        weth = new WETH();

        vm.label(address(this), "TEST_CONTRACT");
        vm.label(feeReceiver, "FEE_RECEIVER");

        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        (bullaClaim,) = (new Deployer()).deploy_test(address(this), feeReceiver, LockState.Unlocked, 0);
        sigHelper = new EIP712Helper(address(bullaClaim));

        weth.transferFrom(address(this), creditor, 1000 ether);
        weth.transferFrom(address(this), debtor, 1000 ether);
        weth.transferFrom(address(this), owner, 1000 ether);

        vm.deal(creditor, 1000 ether);
        vm.deal(debtor, 1000 ether);
        vm.deal(owner, 1000 ether);
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

    function _permitPayClaim(
        uint256 _ownerPK,
        address _operator,
        PayClaimApprovalType _approvalType,
        uint40 _approvalDeadline,
        ClaimPaymentApproval[] memory _paymentApprovals
    ) private {
        Signature memory sig = sigHelper.signPayClaimPermit(
            _ownerPK, vm.addr(_ownerPK), _operator, _approvalType, _approvalDeadline, _paymentApprovals
        );
        bullaClaim.permitPayClaim(
            vm.addr(_ownerPK), _operator, _approvalType, _approvalDeadline, _paymentApprovals, sig
        );
    }

    function _permitPayClaim(uint256 _ownerPK, address _operator, uint40 _approvalDeadline) private {
        ClaimPaymentApproval[] memory approvals = new ClaimPaymentApproval[](0);
        _permitPayClaim(_ownerPK, _operator, PayClaimApprovalType.IsApprovedForAll, _approvalDeadline, approvals);
    }

    ///////// PAY CLAIM FROM TESTS /////////

    // todo:
    // cannot payClaimFrom when contract is locked
    // can payClaimFrom when contract is partially locked

    function testIsApprovedForAll() public {
        // have the creditor permit bob to act as a operator
        _permitPayClaim({_ownerPK: ownerPK, _operator: operator, _approvalDeadline: 0});
        uint256 claimId = _newClaim({_creditor: creditor, _debtor: owner});

        vm.prank(owner);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(operator);
        bullaClaim.payClaimFrom(owner, claimId, 1 ether);
    }
}
