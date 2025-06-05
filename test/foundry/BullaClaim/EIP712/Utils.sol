// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import "contracts/types/Types.sol";
import "safe-contracts/handler/DefaultCallbackHandler.sol";
import "safe-contracts/interfaces/ISignatureValidator.sol";
import "safe-contracts/GnosisSafe.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "contracts/BullaClaim.sol";

address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

function privateKeyValidity(uint256 pk) pure returns (bool) {
    return pk != 0 && pk < 115792089237316195423570985008687907852837564279074904382605163141518161494337;
}

function splitSig(bytes memory sig) pure returns (uint8 v, bytes32 r, bytes32 s) {
    assembly {
        r := mload(add(sig, 0x20))
        s := mload(add(sig, 0x40))
        v := byte(0, mload(add(sig, 0x60)))
    }
}

contract EIP712Helper {
    using Strings for *;

    Vm constant vm = Vm(HEVM_ADDRESS);

    BullaClaim public bullaClaim;
    string public EIP712_NAME;
    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public CREATE_CLAIM_TYPEHASH;

    constructor(address _bullaClaim) {
        bullaClaim = BullaClaim(_bullaClaim);

        DOMAIN_SEPARATOR = bullaClaim.DOMAIN_SEPARATOR();
        CREATE_CLAIM_TYPEHASH = BullaClaimPermitLib.CREATE_CLAIM_TYPEHASH;
    }

    function _hashPermitCreateClaim(
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) internal view returns (bytes32) {
        (CreateClaimApproval memory approvals,,,,,) = bullaClaim.approvals(user, controller);

        return keccak256(
            abi.encode(
                CREATE_CLAIM_TYPEHASH,
                user,
                controller,
                keccak256(
                    bytes(
                        BullaClaimPermitLib.getPermitCreateClaimMessage(
                            bullaClaim.controllerRegistry(), controller, approvalType, approvalCount, isBindingAllowed
                        )
                    )
                ),
                approvalType,
                approvalCount,
                isBindingAllowed,
                approvals.nonce
            )
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getPermitCreateClaimDigest(
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashPermitCreateClaim(user, controller, approvalType, approvalCount, isBindingAllowed)
            )
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getPermitPayClaimDigest(
        address user,
        address controller,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals
    ) public view returns (bytes32) {
        (, PayClaimApproval memory approval,,,,) = bullaClaim.approvals(user, controller);
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                BullaClaimPermitLib.getPermitPayClaimDigest(
                    bullaClaim.controllerRegistry(),
                    user,
                    controller,
                    approvalType,
                    approvalDeadline,
                    paymentApprovals,
                    approval.nonce
                )
            )
        );
    }

    function getPermitUpdateBindingDigest(address user, address controller, uint64 approvalCount)
        public
        view
        returns (bytes32)
    {
        (,, UpdateBindingApproval memory approval,,,) = bullaClaim.approvals(user, controller);
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                BullaClaimPermitLib.getPermitUpdateBindingDigest(
                    bullaClaim.controllerRegistry(), user, controller, approvalCount, approval.nonce
                )
            )
        );
    }

    function getPermitCancelClaimDigest(address user, address controller, uint64 approvalCount)
        public
        view
        returns (bytes32)
    {
        (,,, CancelClaimApproval memory approval,,) = bullaClaim.approvals(user, controller);
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                BullaClaimPermitLib.getPermitCancelClaimDigest(
                    bullaClaim.controllerRegistry(), user, controller, approvalCount, approval.nonce
                )
            )
        );
    }

    function getPermitImpairClaimDigest(address user, address controller, uint64 approvalCount)
        public
        view
        returns (bytes32)
    {
        (,,,, ImpairClaimApproval memory approval,) = bullaClaim.approvals(user, controller);
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                BullaClaimPermitLib.getPermitImpairClaimDigest(
                    bullaClaim.controllerRegistry(), user, controller, approvalCount, approval.nonce
                )
            )
        );
    }

    function getPermitMarkAsPaidDigest(address user, address controller, uint64 approvalCount)
        public
        view
        returns (bytes32)
    {
        (,,,,, MarkAsPaidApproval memory approval) = bullaClaim.approvals(user, controller);
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                BullaClaimPermitLib.getPermitMarkAsPaidDigest(
                    bullaClaim.controllerRegistry(), user, controller, approvalCount, approval.nonce
                )
            )
        );
    }

    function signCreateClaimPermit(
        uint256 pk,
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public returns (bytes memory) {
        bytes32 digest = getPermitCreateClaimDigest(user, controller, approvalType, approvalCount, isBindingAllowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function signPayClaimPermit(
        uint256 pk,
        address user,
        address controller,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals
    ) public returns (bytes memory) {
        bytes32 digest = getPermitPayClaimDigest(user, controller, approvalType, approvalDeadline, paymentApprovals);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function signUpdateBindingPermit(uint256 pk, address user, address controller, uint64 approvalCount)
        public
        returns (bytes memory)
    {
        bytes32 digest = getPermitUpdateBindingDigest(user, controller, approvalCount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function signCancelClaimPermit(uint256 pk, address user, address controller, uint64 approvalCount)
        public
        returns (bytes memory)
    {
        bytes32 digest = getPermitCancelClaimDigest(user, controller, approvalCount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function signImpairClaimPermit(uint256 pk, address user, address controller, uint64 approvalCount)
        public
        returns (bytes memory)
    {
        bytes32 digest = getPermitImpairClaimDigest(user, controller, approvalCount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function signMarkAsPaidPermit(uint256 pk, address user, address controller, uint64 approvalCount)
        public
        returns (bytes memory)
    {
        bytes32 digest = getPermitMarkAsPaidDigest(user, controller, approvalCount);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /*///////////////////// ERC20 PERMIT FUNCTIONALITY /////////////////////*/

    /// @notice Creates an ERC20 permit digest for signing
    /// @param token The ERC20 token contract address
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @param value The approval amount
    /// @param deadline The permit deadline
    /// @return The digest to be signed
    function getERC20PermitDigest(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) public view returns (bytes32) {
        // ERC20 Permit typehash as defined in EIP-2612
        bytes32 PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        
        // Get the token's nonce for this owner
        uint256 nonce;
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("nonces(address)", owner));
        if (success && data.length >= 32) {
            nonce = abi.decode(data, (uint256));
        }
        
        // Get the token's domain separator
        bytes32 domainSeparator;
        (success, data) = token.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        if (success && data.length >= 32) {
            domainSeparator = abi.decode(data, (bytes32));
        }
        
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );
    }

    /// @notice Signs an ERC20 permit
    /// @param pk The private key to sign with
    /// @param token The ERC20 token contract address
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @param value The approval amount
    /// @param deadline The permit deadline
    /// @return The signature bytes (r, s, v format)
    function signERC20Permit(
        uint256 pk,
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) public returns (bytes memory) {
        bytes32 digest = getERC20PermitDigest(token, owner, spender, value, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Signs an ERC20 permit and returns v, r, s components separately
    /// @param pk The private key to sign with
    /// @param token The ERC20 token contract address
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @param value The approval amount
    /// @param deadline The permit deadline
    /// @return v The recovery parameter
    /// @return r The first 32 bytes of the signature
    /// @return s The second 32 bytes of the signature
    function signERC20PermitComponents(
        uint256 pk,
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) public returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = getERC20PermitDigest(token, owner, spender, value, deadline);
        return vm.sign(pk, digest);
    }
}

/// @dev this contract wont compile with solc 0.8.15
contract CompatibilityFallbackHandler_patch is DefaultCallbackHandler, ISignatureValidator {
    //keccak256(
    //    "SafeMessage(bytes message)"
    //);
    bytes32 private constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

    bytes4 internal constant SIMULATE_SELECTOR = bytes4(keccak256("simulate(address,bytes)"));

    address internal constant SENTINEL_MODULES = address(0x1);
    bytes4 internal constant UPDATED_MAGIC_VALUE = 0x1626ba7e;

    /**
     * Implementation of ISignatureValidator (see `interfaces/ISignatureValidator.sol`)
     * @dev Should return whether the signature provided is valid for the provided data.
     * @param _data Arbitrary length data signed on the behalf of address(msg.sender)
     * @param _signature bytes byte array associated with _data
     * @return a bool upon valid or invalid signature with corresponding _data
     */
    function isValidSignature(bytes memory _data, bytes memory _signature) public view override returns (bytes4) {
        // Caller should be a Safe
        GnosisSafe safe = GnosisSafe(payable(msg.sender));
        bytes32 messageHash = getMessageHashForSafe(safe, _data);
        if (_signature.length == 0) {
            require(safe.signedMessages(messageHash) != 0, "Hash not approved");
        } else {
            safe.checkSignatures(messageHash, _data, _signature);
        }
        return EIP1271_MAGIC_VALUE;
    }

    /// @dev Returns hash of a message that can be signed by users.
    /// @param message Message that should be hashed
    /// @return Message hash.
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        return getMessageHashForSafe(GnosisSafe(payable(msg.sender)), message);
    }

    /// @dev Returns hash of a message that can be signed by users.
    /// @param safe Safe to which the message is targeted
    /// @param message Message that should be hashed
    /// @return Message hash.
    function getMessageHashForSafe(GnosisSafe safe, bytes memory message) public view returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), safe.domainSeparator(), safeMessageHash));
    }

    /**
     * Implementation of updated EIP-1271
     * @dev Should return whether the signature provided is valid for the provided data.
     *       The save does not implement the interface since `checkSignatures` is not a view method.
     *       The method will not perform any state changes (see parameters of `checkSignatures`)
     * @param _dataHash Hash of the data signed on the behalf of address(msg.sender)
     * @param _signature bytes byte array associated with _dataHash
     * @return a bool upon valid or invalid signature with corresponding _dataHash
     * @notice See https://github.com/gnosis/util-contracts/blob/bb5fe5fb5df6d8400998094fb1b32a178a47c3a1/contracts/StorageAccessible.sol
     */
    function isValidSignature(bytes32 _dataHash, bytes calldata _signature) external view returns (bytes4) {
        ISignatureValidator validator = ISignatureValidator(msg.sender);
        bytes4 value = validator.isValidSignature(abi.encode(_dataHash), _signature);
        return (value == EIP1271_MAGIC_VALUE) ? UPDATED_MAGIC_VALUE : bytes4(0);
    }

    /// @dev Returns array of first 10 modules.
    /// @return Array of modules.
    function getModules() external view returns (address[] memory) {
        // Caller should be a Safe
        GnosisSafe safe = GnosisSafe(payable(msg.sender));
        (address[] memory array,) = safe.getModulesPaginated(SENTINEL_MODULES, 10);
        return array;
    }

    /**
     * @dev Performs a delegatecall on a targetContract in the context of self.
     * Internally reverts execution to avoid side effects (making it static). Catches revert and returns encoded result as bytes.
     * @param targetContract Address of the contract containing the code to execute.
     * @param calldataPayload Calldata that should be sent to the target contract (encoded method name and arguments).
     */
    function simulate(address targetContract, bytes calldata calldataPayload)
        external
        returns (bytes memory response)
    {
        // Suppress compiler warnings about not using parameters, while allowing
        // parameters to keep names for documentation purposes. This does not
        // generate code.
        targetContract;
        calldataPayload;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            let internalCalldata := mload(0x40)
            // Store `simulateAndRevert.selector`.
            // String representation is used to force right padding
            mstore(internalCalldata, "\xb4\xfa\xba\x09")
            // Abuse the fact that both this and the internal methods have the
            // same signature, and differ only in symbol name (and therefore,
            // selector) and copy calldata directly. This saves us approximately
            // 250 bytes of code and 300 gas at runtime over the
            // `abi.encodeWithSelector` builtin.
            calldatacopy(add(internalCalldata, 0x04), 0x04, sub(calldatasize(), 0x04))

            // `pop` is required here by the compiler, as top level expressions
            // can't have return values in inline assembly. `call` typically
            // returns a 0 or 1 value indicated whether or not it reverted, but
            // since we know it will always revert, we can safely ignore it.
            pop(
                call(
                    gas(),
                    // address() has been changed to caller() to use the implementation of the Safe
                    caller(),
                    0,
                    internalCalldata,
                    calldatasize(),
                    // The `simulateAndRevert` call always reverts, and
                    // instead encodes whether or not it was successful in the return
                    // data. The first 32-byte word of the return data contains the
                    // `success` value, so write it to memory address 0x00 (which is
                    // reserved Solidity scratch space and OK to use).
                    0x00,
                    0x20
                )
            )

            // Allocate and copy the response bytes, making sure to increment
            // the free memory pointer accordingly (in case this method is
            // called as an internal function). The remaining `returndata[0x20:]`
            // contains the ABI encoded response bytes, so we can just write it
            // as is to memory.
            let responseSize := sub(returndatasize(), 0x20)
            response := mload(0x40)
            mstore(0x40, add(response, responseSize))
            returndatacopy(response, 0x20, responseSize)

            if iszero(mload(0x00)) { revert(add(response, 0x20), mload(response)) }
        }
    }
}
