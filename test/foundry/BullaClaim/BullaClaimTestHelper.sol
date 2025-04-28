// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import "contracts/BullaClaim.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";

contract BullaClaimTestHelper is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;

    string tokenURI = "https://mytokenURI.com/1234";
    string attachmentURI = "https://coolcatpics.com/1234";

    function _newClaim(address _creator, address _creditor, address _debtor) internal returns (uint256 claimId) {
        vm.prank(_creator);
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function _newClaimFrom(address _from, address _creditor, address _debtor) internal returns (uint256 claimId) {
        claimId = bullaClaim.createClaimFrom(
            _from,
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function _newClaimWithMetadataFrom(address _from, address _creditor, address _debtor)
        internal
        returns (uint256 claimId)
    {
        claimId = bullaClaim.createClaimWithMetadataFrom(
            _from,
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function _permitCreateClaim(
        uint256 _userPK,
        address _operator,
        uint64 _approvalCount,
        CreateClaimApprovalType _approvalType,
        bool _isBindingAllowed
    ) internal {
        bytes memory sig = sigHelper.signCreateClaimPermit(
            _userPK, vm.addr(_userPK), _operator, _approvalType, _approvalCount, _isBindingAllowed
        );
        bullaClaim.permitCreateClaim(vm.addr(_userPK), _operator, _approvalType, _approvalCount, _isBindingAllowed, sig);
    }

    function _permitPayClaim(
        uint256 _userPK,
        address _operator,
        PayClaimApprovalType _approvalType,
        uint256 _approvalDeadline,
        ClaimPaymentApprovalParam[] memory _paymentApprovals
    ) internal {
        address user = vm.addr(_userPK);

        bullaClaim.permitPayClaim({
            user: user,
            operator: _operator,
            approvalType: _approvalType,
            approvalDeadline: _approvalDeadline,
            paymentApprovals: _paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: _userPK,
                user: user,
                operator: _operator,
                approvalType: _approvalType,
                approvalDeadline: _approvalDeadline,
                paymentApprovals: _paymentApprovals
            })
        });
    }

    function _generateClaimPaymentApprovals(uint8 count, address _creditor, address _debtor)
        internal
        returns (ClaimPaymentApprovalParam[] memory)
    {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 claimId = _newClaim({_creator: _creditor, _creditor: _creditor, _debtor: _debtor});
            paymentApprovals[i] =
                ClaimPaymentApprovalParam({claimId: claimId, approvedAmount: 1 ether, approvalDeadline: 0});
        }
        return paymentApprovals;
    }

    function _permitCreateClaim(uint256 _userPK, address _operator, uint64 _approvalCount) internal {
        _permitCreateClaim(_userPK, _operator, _approvalCount, CreateClaimApprovalType.Approved, true);
    }

    function _permitUpdateBinding(uint256 _userPK, address _operator, uint64 _approvalCount) internal {
        bytes memory sig = sigHelper.signUpdateBindingPermit(_userPK, vm.addr(_userPK), _operator, _approvalCount);
        bullaClaim.permitUpdateBinding(vm.addr(_userPK), _operator, _approvalCount, sig);
    }

    function _permitCancelClaim(uint256 _userPK, address _operator, uint64 _approvalCount) internal {
        bytes memory sig = sigHelper.signCancelClaimPermit(_userPK, vm.addr(_userPK), _operator, _approvalCount);
        bullaClaim.permitCancelClaim(vm.addr(_userPK), _operator, _approvalCount, sig);
    }
}
