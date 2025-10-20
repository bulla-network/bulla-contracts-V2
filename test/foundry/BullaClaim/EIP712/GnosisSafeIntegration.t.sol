// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import "contracts/BullaClaimV2.sol";
import "contracts/mocks/PenalizedClaim.sol";
import "contracts/mocks/ERC1271Wallet.sol";
import {GnosisSafe, Enum} from "safe-contracts/GnosisSafe.sol";
import "safe-contracts/proxies/GnosisSafeProxyFactory.sol";
import {SignMessageLib} from "safe-contracts/libraries/SignMessageLib.sol";
import {EIP712Helper, CompatibilityFallbackHandler_patch} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

contract TestGnosisSafeSignatures is Test {
    uint256 alicePK = uint256(12345);
    uint256 bobPK = uint256(98765);

    address alice = vm.addr(alicePK);
    address bob = vm.addr(bobPK);

    BullaClaimV2 internal bullaClaim;
    EIP712Helper internal sigHelper;
    GnosisSafe internal safe;
    SignMessageLib internal signMessageLib;

    function _setup(address[] memory _owners) internal {
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);

        sigHelper = new EIP712Helper(address(bullaClaim));
        CompatibilityFallbackHandler_patch handler = new CompatibilityFallbackHandler_patch();
        GnosisSafe singleton = new GnosisSafe();
        GnosisSafeProxyFactory proxyFactory = new GnosisSafeProxyFactory();
        signMessageLib = new SignMessageLib();

        safe = GnosisSafe(payable(proxyFactory.createProxy(address(singleton), "")));

        safe.setup({
            _owners: _owners,
            _threshold: _owners.length,
            to: address(0),
            data: "",
            fallbackHandler: address(handler),
            paymentToken: address(0),
            payment: 0,
            paymentReceiver: payable(address(0))
        });
    }

    function testCreateClaimPermit() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;

        _setup(owners);

        address safeAddress = address(safe);
        address controller = address(0xB0b);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            user: safeAddress,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        bytes memory txHashData = safe.encodeTransactionData({
            to: address(signMessageLib),
            value: 0,
            data: abi.encodeWithSelector(SignMessageLib.signMessage.selector, abi.encodePacked(digest)),
            operation: Enum.Operation.DelegateCall,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: address(0),
            _nonce: safe.nonce()
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, keccak256(txHashData));
        bytes memory signature = abi.encodePacked(r, s, v);

        safe.execTransaction({
            to: address(signMessageLib),
            value: 0,
            data: abi.encodeWithSelector(SignMessageLib.signMessage.selector, abi.encodePacked(digest)),
            operation: Enum.Operation.DelegateCall,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: payable(address(0)),
            signatures: signature
        });

        bytes32 safeDigest = CompatibilityFallbackHandler_patch(safeAddress).getMessageHash(abi.encodePacked(digest));

        assertEq(safe.signedMessages(safeDigest), 1);
        assertEq(IERC1271(safeAddress).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);

        bullaClaim.approvalRegistry().permitCreateClaim({
            user: safeAddress,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: bytes("")
        });

        CreateClaimApproval memory approval = bullaClaim.approvalRegistry().getApprovals(safeAddress, controller);

        assertEq(approval.approvalCount, approvalCount);
    }

    function testPermitWithSigsOnly() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = bob;
        _setup(owners);

        address safeAddress = address(safe);
        address controller = address(0xB0b);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            user: safeAddress,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed
        });

        bytes32 safeDigest =
            CompatibilityFallbackHandler_patch(safeAddress).getMessageHashForSafe(safe, abi.encodePacked(digest));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, safeDigest);
        bytes memory aliceSig = abi.encodePacked(r, s, v);

        (v, r, s) = vm.sign(bobPK, safeDigest);

        bytes memory bobSig = abi.encodePacked(r, s, v);
        bytes memory signature = alice < bob ? bytes.concat(aliceSig, bobSig) : bytes.concat(bobSig, aliceSig);

        bullaClaim.approvalRegistry().permitCreateClaim({
            user: safeAddress,
            controller: controller,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: signature
        });

        CreateClaimApproval memory approval = bullaClaim.approvalRegistry().getApprovals(safeAddress, controller);
        assertEq(approval.approvalCount, approvalCount);
    }
}
