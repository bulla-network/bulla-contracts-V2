// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import "contracts/BullaClaim.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

contract BullaClaimTestHelper is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;

    string tokenURI = "https://mytokenURI.com/1234";
    string attachmentURI = "https://coolcatpics.com/1234";

    function _newClaim(address _creator, address _creditor, address _debtor) internal returns (uint256 claimId) {
        vm.startPrank(_creator);
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                token: address(weth),
                description: "",
                binding: ClaimBinding.Unbound,
                claimAmount: 1 ether,
                payerReceivesClaimOnPayment: true,
                dueBy: 0,
                impairmentGracePeriod: 0
            })
        );
        vm.stopPrank();
    }

    function _newClaimFrom(address _from, address _creditor, address _debtor) internal returns (uint256 claimId) {
        claimId = bullaClaim.createClaimFrom(
            _from,
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                token: address(weth),
                description: "",
                binding: ClaimBinding.Unbound,
                claimAmount: 1 ether,
                payerReceivesClaimOnPayment: true,
                dueBy: 0,
                impairmentGracePeriod: 0
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
                token: address(weth),
                description: "",
                binding: ClaimBinding.Unbound,
                claimAmount: 1 ether,
                payerReceivesClaimOnPayment: true,
                dueBy: 0,
                impairmentGracePeriod: 0
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function _permitCreateClaim(
        uint256 _userPK,
        address _controller,
        uint64 _approvalCount,
        CreateClaimApprovalType _approvalType,
        bool _isBindingAllowed
    ) internal {
        bytes memory sig = sigHelper.signCreateClaimPermit(
            _userPK, vm.addr(_userPK), _controller, _approvalType, _approvalCount, _isBindingAllowed
        );
        bullaClaim.permitCreateClaim(
            vm.addr(_userPK), _controller, _approvalType, _approvalCount, _isBindingAllowed, sig
        );
    }

    function _permitPayClaim(
        uint256 _userPK,
        address _controller,
        PayClaimApprovalType _approvalType,
        uint256 _approvalDeadline,
        ClaimPaymentApprovalParam[] memory _paymentApprovals
    ) internal {
        address user = vm.addr(_userPK);

        bullaClaim.permitPayClaim({
            user: user,
            controller: _controller,
            approvalType: _approvalType,
            approvalDeadline: _approvalDeadline,
            paymentApprovals: _paymentApprovals,
            signature: sigHelper.signPayClaimPermit({
                pk: _userPK,
                user: user,
                controller: _controller,
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

    function _permitCreateClaim(uint256 _userPK, address _controller, uint64 _approvalCount) internal {
        _permitCreateClaim(_userPK, _controller, _approvalCount, CreateClaimApprovalType.Approved, true);
    }

    function _permitUpdateBinding(uint256 _userPK, address _controller, uint64 _approvalCount) internal {
        bytes memory sig = sigHelper.signUpdateBindingPermit(_userPK, vm.addr(_userPK), _controller, _approvalCount);
        bullaClaim.permitUpdateBinding(vm.addr(_userPK), _controller, _approvalCount, sig);
    }

    function _permitCancelClaim(uint256 _userPK, address _controller, uint64 _approvalCount) internal {
        bytes memory sig = sigHelper.signCancelClaimPermit(_userPK, vm.addr(_userPK), _controller, _approvalCount);
        bullaClaim.permitCancelClaim(vm.addr(_userPK), _controller, _approvalCount, sig);
    }

    function _permitImpairClaim(uint256 _userPK, address _controller, uint64 _approvalCount) internal {
        bytes memory sig = sigHelper.signImpairClaimPermit(_userPK, vm.addr(_userPK), _controller, _approvalCount);
        bullaClaim.permitImpairClaim(vm.addr(_userPK), _controller, _approvalCount, sig);
    }

    function _permitMarkAsPaid(uint256 _userPK, address _controller, uint64 _approvalCount) internal {
        bytes memory sig = sigHelper.signMarkAsPaidPermit(_userPK, vm.addr(_userPK), _controller, _approvalCount);
        bullaClaim.permitMarkAsPaid(vm.addr(_userPK), _controller, _approvalCount, sig);
    }

    function _permitERC20Token(uint256 _ownerPK, address _token, address _spender, uint256 _amount, uint256 _deadline)
        internal
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(_ownerPK);
        return sigHelper.signERC20PermitComponents(_ownerPK, _token, owner, _spender, _amount, _deadline);
    }
}
