// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import "contracts/BullaClaimV2.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

contract BullaClaimTestHelper is Test {
    WETH public weth;
    BullaClaimV2 internal bullaClaim;
    IBullaApprovalRegistry internal approvalRegistry;
    EIP712Helper internal sigHelper;

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
        approvalRegistry.permitCreateClaim(
            vm.addr(_userPK), _controller, _approvalType, _approvalCount, _isBindingAllowed, sig
        );
    }

    function _permitCreateClaim(uint256 _userPK, address _controller, uint64 _approvalCount) internal {
        _permitCreateClaim(_userPK, _controller, _approvalCount, CreateClaimApprovalType.Approved, true);
    }

    function _permitERC20Token(uint256 _ownerPK, address _token, address _spender, uint256 _amount, uint256 _deadline)
        internal
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(_ownerPK);
        return sigHelper.signERC20PermitComponents(_ownerPK, _token, owner, _spender, _amount, _deadline);
    }
}
