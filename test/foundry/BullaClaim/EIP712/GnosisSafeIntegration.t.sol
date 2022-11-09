// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import "contracts/BullaClaim.sol";
import "contracts/mocks/PenalizedClaim.sol";
import "contracts/mocks/ERC1271Wallet.sol";
import "safe-contracts/GnosisSafe.sol";
import "safe-contracts/proxies/GnosisSafeProxyFactory.sol";
import "safe-contracts/proxies/GnosisSafeProxyFactory.sol";
import "safe-contracts/libraries/SignMessageLib.sol";
import "test/foundry/BullaClaim/EIP712/Utils.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

contract TestGnosisSafeSignatures is Test {
    uint256 alicePK = uint256(12345);
    address alice = vm.addr(alicePK);

    BullaClaim internal bullaClaim;
    EIP712Helper internal sigHelper;
    GnosisSafe internal safe;
    SignMessageLib internal signMessageLib;

    function setUp() public {
        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });

        sigHelper = new EIP712Helper(address(bullaClaim));
        CompatibilityFallbackHandlerFIXED handler = new CompatibilityFallbackHandlerFIXED();
        GnosisSafe singleton = new GnosisSafe();
        GnosisSafeProxyFactory proxyFactory = new GnosisSafeProxyFactory();
        signMessageLib = new SignMessageLib();

        safe = GnosisSafe(payable(proxyFactory.createProxy(address(singleton), "")));

        address[] memory owners = new address[](1);
        owners[0] = alice;

        safe.setup({
            _owners: owners,
            _threshold: 1,
            to: address(0),
            data: "",
            fallbackHandler: address(handler),
            paymentToken: address(0),
            payment: 0,
            paymentReceiver: payable(address(0))
        });
    }

    function testCreateClaimPermit() public {
        address safeAddress = address(safe);
        address operator = address(0xB0b);

        CreateClaimApprovalType approvalType = CreateClaimApprovalType.Approved;
        uint64 approvalCount = 1;
        bool isBindingAllowed = true;

        bytes32 digest = sigHelper.getPermitCreateClaimDigest({
            owner: safeAddress,
            operator: operator,
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

        bytes32 safeDigest = CompatibilityFallbackHandlerFIXED(safeAddress).getMessageHash(abi.encodePacked(digest));
        assertEq(safe.signedMessages(safeDigest), 1);

        assertEq(IERC1271(safeAddress).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);

        bullaClaim.permitCreateClaim({
            owner: safeAddress,
            operator: operator,
            approvalType: approvalType,
            approvalCount: approvalCount,
            isBindingAllowed: isBindingAllowed,
            signature: Signature(0, 0, 0)
        });

        (CreateClaimApproval memory approval,,,) = bullaClaim.approvals(safeAddress, operator);

        assertEq(approval.approvalCount, approvalCount);
    }
}
