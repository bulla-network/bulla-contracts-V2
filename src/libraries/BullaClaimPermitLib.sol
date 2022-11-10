// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import "contracts/interfaces/IERC1271.sol";
import "contracts/BullaClaim.sol";
import {BullaExtensionRegistry} from "contracts/BullaExtensionRegistry.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

library BullaClaimPermitLib {
    using Strings for uint256;
    using Strings for address;

    event CreateClaimApproved(
        address indexed user,
        address indexed operator,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    event PayClaimApproved(
        address indexed user,
        address indexed operator,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] paymentApprovals
    );

    event UpdateBindingApproved(address indexed user, address indexed operator, uint256 approvalCount);

    event CancelClaimApproved(address indexed user, address indexed operator, uint256 approvalCount);

    bytes32 constant CREATE_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCreateClaimExtension(address user,address operator,string message,uint8 approvalType,uint256 approvalCount,bool isBindingAllowed,uint256 nonce)"
        )
    );

    bytes32 constant CLAIM_PAYMENT_APPROVAL_TYPEHASH =
        keccak256(bytes("ClaimPaymentApproval(uint256 claimId,uint256 approvalDeadline,uint256 approvedAmount)"));

    bytes32 constant PAY_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApprovePayClaimExtension(address user,address operator,string message,uint8 approvalType,uint256 approvalDeadline,ClaimPaymentApproval[] paymentApprovals,uint256 nonce)ClaimPaymentApproval(uint256 claimId,uint256 approvalDeadline,uint256 approvedAmount)"
        )
    );

    bytes32 constant CANCEL_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCancelClaimExtension(address user,address operator,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    bytes32 constant UPDATE_BINDING_TYPEHASH = keccak256(
        bytes(
            "ApproveUpdateBindingExtension(address user,address operator,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    /// @dev copied and modified from OpenZeppelin's SignatureChecker
    function _validateSignature(address signer, bytes32 digest, Signature calldata signature)
        internal
        view
        returns (bool)
    {
        address recoveredAddress = ecrecover(digest, signature.v, signature.r, signature.s);

        if (recoveredAddress != signer || recoveredAddress == address(0)) {
            bytes memory byteSig = signature.r == bytes32(0) && signature.s == bytes32(0) && signature.v == 0
                ? bytes("")
                : abi.encodePacked(signature.r, signature.s, signature.v);

            (bool success, bytes memory result) =
                signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, byteSig));

            return (
                success && result.length == 32
                    && abi.decode(result, (bytes32)) == bytes32(IERC1271.isValidSignature.selector)
            );
        } else {
            return true;
        }
    }

    /*
    ////// PERMIT MESSAGES //////
    */
    function getPermitCreateClaimMessage(
        BullaExtensionRegistry extensionRegistry,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (string memory) {
        return approvalCount > 0 // approve case:
            ? string.concat(
                "I approve the following contract: ", // todo: add \n new lines
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(), // note: will _not_ be checksummed
                ") ",
                "to create ",
                approvalCount != type(uint64).max ? string.concat(uint256(approvalCount).toString(), " ") : "",
                "claims on my behalf.",
                approvalType != CreateClaimApprovalType.CreditorOnly
                    ? string.concat(
                        " I acknowledge that this contract may indebt me on claims",
                        isBindingAllowed ? " that I cannot reject." : "."
                    )
                    : ""
            ) // revoke case
            : string.concat(
                "I revoke approval for the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(),
                ") ",
                "to create claims on my behalf."
            );
    }

    function getPermitPayClaimMessage(
        BullaExtensionRegistry extensionRegistry,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline
    ) public view returns (string memory) {
        return approvalType != PayClaimApprovalType.Unapproved // approve case:
            ? string.concat(
                approvalType == PayClaimApprovalType.IsApprovedForAll ? "ATTENTION!: " : "",
                "I approve the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(), // note: will _not_ be checksummed
                ") ",
                "to pay ",
                approvalType == PayClaimApprovalType.IsApprovedForAll ? "any claim" : "the below claims",
                " on my behalf. I understand that once I sign this message this contract can spend tokens I've approved",
                approvalDeadline != 0 ? string.concat(" until the timestamp: ", uint256(approvalDeadline).toString()) : "."
            ) // revoke case
            : string.concat(
                "I revoke approval for the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(),
                ") ",
                "pay claims on my behalf."
            );
    }

    function getPermitCancelClaimMessage(
        BullaExtensionRegistry extensionRegistry,
        address operator,
        uint64 approvalCount
    ) public view returns (string memory) {
        return approvalCount > 0 // approve case:
            ? string.concat(
                "I grant ",
                approvalCount != type(uint64).max ? "limited " : "",
                "approval to the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(), // note: will _not_ be checksummed
                ") to cancel claims on my behalf."
            ) // revoke case
            : string.concat(
                "I revoke approval for the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(),
                ") ",
                "cancel claims on my behalf."
            );
    }

    function getPermitUpdateBindingMessage(
        BullaExtensionRegistry extensionRegistry,
        address operator,
        uint64 approvalCount
    ) public view returns (string memory) {
        return approvalCount > 0 // approve case:
            ? string.concat(
                "I grant ",
                approvalCount != type(uint64).max ? "limited " : "",
                "approval to the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(), // note: will _not_ be checksummed
                ") to bind me to claims or unbind my claims."
            ) // revoke case
            : string.concat(
                "I revoke approval for the following contract: ",
                extensionRegistry.getExtensionForSignature(operator),
                " (",
                operator.toHexString(),
                ") ",
                "to update claim binding."
            );
    }

    /*
    ////// PERMIT DIGESTS //////
    */

    function getPermitCreateClaimDigest(
        BullaExtensionRegistry extensionRegistry,
        address user,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BullaClaimPermitLib.CREATE_CLAIM_TYPEHASH, // spec.S1
                user, // spec.S2
                operator, // spec.S3
                // spec.S4
                keccak256(
                    bytes(
                        getPermitCreateClaimMessage(
                            extensionRegistry, // spec.A4 // spec.R4 /// WARNING: this could revert!
                            operator,
                            approvalType,
                            approvalCount,
                            isBindingAllowed
                        )
                    )
                ),
                approvalType, // spec.S5
                approvalCount, // spec.S6
                isBindingAllowed, // spec.S7
                nonce // spec.S8
            )
        );
    }

    function hashPaymentApprovals(ClaimPaymentApprovalParam[] calldata paymentApprovals)
        public
        pure
        returns (bytes32)
    {
        bytes32[] memory approvalHashes = new bytes32[](
            paymentApprovals.length
        );
        for (uint256 i; i < paymentApprovals.length; ++i) {
            approvalHashes[i] = keccak256(
                abi.encode(
                    BullaClaimPermitLib.CLAIM_PAYMENT_APPROVAL_TYPEHASH,
                    paymentApprovals[i].claimId,
                    paymentApprovals[i].approvalDeadline,
                    paymentApprovals[i].approvedAmount
                )
            );
        }
        return keccak256(abi.encodePacked(approvalHashes));
    }

    function getPermitPayClaimDigest(
        BullaExtensionRegistry extensionRegistry,
        address user,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals,
        uint256 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                PAY_CLAIM_TYPEHASH,
                user,
                operator,
                keccak256(bytes(getPermitPayClaimMessage(extensionRegistry, operator, approvalType, approvalDeadline))),
                approvalType,
                approvalDeadline,
                hashPaymentApprovals(paymentApprovals),
                nonce
            )
        );
    }

    function getPermitCancelClaimDigest(
        BullaExtensionRegistry extensionRegistry,
        address user,
        address operator,
        uint64 approvalCount,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BullaClaimPermitLib.CANCEL_CLAIM_TYPEHASH,
                user,
                operator,
                keccak256(bytes(getPermitCancelClaimMessage(extensionRegistry, operator, approvalCount))),
                approvalCount,
                nonce
            )
        );
    }

    function getPermitUpdateBindingDigest(
        BullaExtensionRegistry extensionRegistry,
        address user,
        address operator,
        uint64 approvalCount,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BullaClaimPermitLib.UPDATE_BINDING_TYPEHASH,
                user,
                operator,
                keccak256(bytes(getPermitUpdateBindingMessage(extensionRegistry, operator, approvalCount))),
                approvalCount,
                nonce
            )
        );
    }

    /*///////////////////////////////////////////////////////////////
                       PERMIT LOGIC FOR BULLA CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice allows a user - via a signature - to appove an operator to call createClaim on their behalf
    /// @notice SPEC:
    /// Anyone can call this function with a valid signature to modify the `user`'s CreateClaimApproval of `operator` to the provided parameters
    /// In all cases:
    ///     SIG1: The recovered signer from the EIP712 signature == `user`
    ///     SIG2: `user` is not a 0 address
    ///     SIG3: `extensionRegistry` is not address(0)
    /// This function can _approve_ an operator given:
    ///     A1: 0 < `approvalCount` < type(uint64).max
    /// This function can _revoke_ an operator given:
    ///     R1: `approvalCount` == 0
    ///
    /// A valid approval signature is defined as: a signed EIP712 hash digest of the following parameters:
    ///     S1: The hash of the EIP712 typedef string
    ///     S2: The `user` address
    ///     S3: The `operator` address
    ///     S4: A verbose approval message: see `BullaClaimPermitLib.getPermitCreateClaimMessage()`
    ///     S5: The `approvalType` enum as a uint8
    ///     S6: The `approvalCount`
    ///     S7: The `isBindingAllowed` boolean flag
    ///     S8: The stored signing nonce found in `user`'s CreateClaimApproval struct for `operator`

    /// Result: If the above conditions are met:
    ///     RES1: The nonce is incremented
    ///     RES2: The `user`'s approval of `operator` is updated
    ///     RES3: A CreateClaimApproved event is emitted with the approval parameters
    function permitCreateClaim(
        Approvals storage approvals,
        BullaExtensionRegistry extensionRegistry,
        bytes32 domainSeparator,
        address user,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        Signature calldata signature
    ) public {
        uint64 nonce = approvals.createClaim.nonce;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                getPermitCreateClaimDigest(
                    extensionRegistry, user, operator, approvalType, approvalCount, isBindingAllowed, nonce
                )
            )
        );

        if (
            !_validateSignature(user, digest, signature) // spec.A1, spec.A2, spec.R1, spec.R2
        ) revert BullaClaim.InvalidSignature();

        if (approvalCount > 0) {
            // spec.A3
            approvals.createClaim.isBindingAllowed = isBindingAllowed; // spec.RES2
            approvals.createClaim.approvalType = approvalType; // spec.RES2
            approvals.createClaim.approvalCount = approvalCount; // spec.RES2
            approvals.createClaim.nonce++; // spec.RES1
        } else {
            // spec.R3
            delete approvals.createClaim.isBindingAllowed; // spec.RES2
            delete approvals.createClaim.approvalType; // spec.RES2
            delete approvals.createClaim.approvalCount; // spec.RES2
            approvals.createClaim.nonce++; // spec.RES1
        }

        // spec.RES3
        emit CreateClaimApproved(user, operator, approvalType, approvalCount, isBindingAllowed);
    }

    /// @notice permitPayClaim() allows a user, via a signature, to appove an operator to call payClaim on their behalf
    /// @notice SPEC:
    /// Anyone can call this function with a valid signature to set `user`'s PayClaimApproval of `operator` to the provided parameters.
    /// A user may signal 3 different approval types through this function: "Unapproved", "Approved for specific claims only", and "Approved for all claims".
    /// In all cases:
    ///     SIG1: The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
    ///     SIG2: `user` is not the 0 address -> otherwise: reverts
    /// This function can approve an operator to pay _specific_ claims given the following conditions listed below as AS - (Approve Specific 1-5):
    ///     AS1: `approvalType` == PayClaimApprovalType.IsApprovedForSpecific
    ///     AS2: `approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
    ///     AS3: `paymentApprovals.length > 0` and contains valid `ClaimPaymentApprovals` -> otherwise: reverts
    ///     A valid ClaimPaymentApproval is defined as the following:
    ///         AS3.1: `ClaimPaymentApproval.claimId` is < type(uint88).max -> otherwise: reverts
    ///         AS3.2: `ClaimPaymentApproval.approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
    ///         AS3.3: `ClaimPaymentApproval.approvedAmount` < type(uint128).max -> otherwise: reverts
    ///   RESULT: The following call parameters are stored on on `user`'s approval of `operator`
    ///     AS.RES1: The approvalType = PayClaimApprovalType.IsApprovedForSpecific
    ///     AS.RES2: The approvalDeadline is stored if not 0
    ///     AS.RES3: The nonce is incremented by 1
    ///     AS.RES4. ClaimApprovals specified in calldata are stored and overwrite previous approvals
    ///     AS.RES5: A PayClaimApproval event is emitted
    ///
    /// This function can approve an operator to pay _all_ claims given the following conditions listed below as AA - (Approve All 1-5):
    ///     AA1: `approvalType` == PayClaimApprovalType.IsApprovedForAll
    ///     AA2: `approvalDeadline` is either 0 (indicating unexpiring approval) or block.timestamp < `approvalDeadline` < type(uint40).max -> otherwise reverts
    ///     AA3: `paymentApprovals.length == 0` -> otherwise: reverts
    ///   RESULT: The following call parameters are stored on on `user`'s approval of `operator`
    ///     AA.RES1: The approvalType = PayClaimApprovalType.IsApprovedForAll
    ///     AA.RES2: The nonce is incremented by 1
    ///     AA.RES3: If the previous approvalType == PayClaimApprovalType.IsApprovedForSpecific, delete the claimApprovals array -> otherwise: continue
    ///     AA.RES4: A PayClaimApproval event is emitted
    ///
    /// This function can _revoke_ an operator to pay claims given the following conditions listed below as AR - (Approval Revoked 1-5):
    ///     AR1: `approvalType` == PayClaimApprovalType.Unapproved
    ///     AR2: `approvalDeadline` == 0 -> otherwise: reverts
    ///     AR3: `paymentApprovals.length` == 0 -> otherwise: reverts
    ///   RESULT: `user`'s approval of `operator` is updated to the following:
    ///     AR.RES1: approvalType is deleted (equivalent to being set to `Unapproved`)
    ///     AR.RES2: approvalDeadline is deleted
    ///     AR.RES3: The nonce is incremented by 1
    ///     AR.RES4: The claimApprovals array is deleted
    ///     AR.RES5: A PayClaimApproval event is emitted

    /// A valid approval signature is defined as: a signed EIP712 hash digest of the following parameters:
    ///     S1: The hash of the EIP712 typedef string
    ///     S2: The `user` address
    ///     S3: The `operator` address
    ///     S4: A verbose approval message: see `BullaClaimPermitLib.getPermitPayClaimMessage()`
    ///     S5: The `approvalType` enum as a uint8
    ///     S6: The `approvalDeadline` as uint256
    ///     S7: The keccak256 hash of the abi.encodePacked array of the keccak256 hashStruct of ClaimPaymentApproval typehash and contents
    ///     S8: The stored signing nonce found in `user`'s PayClaimApproval struct for `operator`
    function permitPayClaim(
        Approvals storage approvals,
        BullaExtensionRegistry extensionRegistry,
        bytes32 domainSeparator,
        address user,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals,
        Signature calldata signature
    ) public {
        uint64 nonce = approvals.payClaim.nonce;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                getPermitPayClaimDigest(
                    extensionRegistry, user, operator, approvalType, approvalDeadline, paymentApprovals, nonce
                )
            )
        );

        if (!_validateSignature(user, digest, signature)) revert BullaClaim.InvalidSignature();
        if (approvalDeadline != 0 && (approvalDeadline < block.timestamp || approvalDeadline > type(uint40).max)) {
            revert BullaClaim.InvalidTimestamp(approvalDeadline);
        }

        if (approvalType == PayClaimApprovalType.IsApprovedForAll) {
            if (paymentApprovals.length > 0) revert BullaClaim.InvalidPaymentApproval();

            approvals.payClaim.approvalType = PayClaimApprovalType.IsApprovedForAll;
            approvals.payClaim.approvalDeadline = uint40(approvalDeadline); // cast is safe because we check it above
            delete approvals.payClaim.claimApprovals;
        } else if (approvalType == PayClaimApprovalType.IsApprovedForSpecific) {
            if (paymentApprovals.length == 0) revert BullaClaim.InvalidPaymentApproval();

            for (uint256 i; i < paymentApprovals.length; ++i) {
                if (
                    paymentApprovals[i].claimId > type(uint88).max
                        || paymentApprovals[i].approvedAmount > type(uint128).max
                ) revert BullaClaim.InvalidPaymentApproval();
                if (
                    paymentApprovals[i].approvalDeadline != 0
                        && (
                            paymentApprovals[i].approvalDeadline < block.timestamp
                                || paymentApprovals[i].approvalDeadline > type(uint40).max
                        )
                ) {
                    revert BullaClaim.InvalidTimestamp(paymentApprovals[i].approvalDeadline);
                }

                approvals.payClaim.claimApprovals.push(
                    ClaimPaymentApproval({
                        claimId: uint88(paymentApprovals[i].claimId),
                        approvalDeadline: uint40(paymentApprovals[i].approvalDeadline),
                        approvedAmount: uint128(paymentApprovals[i].approvedAmount)
                    })
                );
            }

            approvals.payClaim.approvalType = PayClaimApprovalType.IsApprovedForSpecific;
            approvals.payClaim.approvalDeadline = uint40(approvalDeadline);
        } else {
            if (approvalDeadline != 0 || paymentApprovals.length > 0) {
                revert BullaClaim.InvalidPaymentApproval();
            }

            delete approvals.payClaim.approvalType; // will reset back to 0, which is unapproved
            delete approvals.payClaim.approvalDeadline;
            delete approvals.payClaim.claimApprovals;
        }

        approvals.payClaim.nonce++;

        emit PayClaimApproved(user, operator, approvalType, approvalDeadline, paymentApprovals);
    }

    /// @notice permitUpdateBinding() allows a user, via a signature, to appove an operator to call updateBinding on their behalf
    /// @notice SPEC:
    /// This function can approve an operator to update the binding on claims given the following conditions:
    ///     SIG1. The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
    ///     SIG2. `user` is not the 0 address -> otherwise: reverts
    ///     SIG3. `extensionRegistry` is not address(0)
    /// This function can approve an operator to update a claim's binding given:
    ///     AB1: 0 < `approvalCount` < type(uint64).max -> otherwise reverts
    /// This function can revoke an operator's approval to update a claim's binding given:
    ///     RB1: approvalCount == 0
    ///
    ///     RES1: approvalCount is stored
    ///     RES2: the nonce is incremented
    ///     RES3: the UpdateBindingApproved event is emitted
    function permitUpdateBinding(
        Approvals storage approvals,
        BullaExtensionRegistry extensionRegistry,
        bytes32 domainSeparator,
        address user,
        address operator,
        uint64 approvalCount,
        Signature calldata signature
    ) public {
        uint64 nonce = approvals.updateBinding.nonce;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                getPermitUpdateBindingDigest(extensionRegistry, user, operator, approvalCount, nonce)
            )
        );

        if (!_validateSignature(user, digest, signature)) revert BullaClaim.InvalidSignature();

        approvals.updateBinding.approvalCount = approvalCount;
        approvals.updateBinding.nonce++;

        emit UpdateBindingApproved(user, operator, approvalCount);
    }

    /// @notice permitCancelClaim() allows a user, via a signature, to appove an operator to call cancelClaim on their behalf
    /// @notice SPEC:
    /// A user can specify an operator address to call `cancelClaim` on their behalf under the following conditions:
    ///     SIG1. The recovered signer from the EIP712 signature == `user` -> otherwise: reverts
    ///     SIG2. `user` is not the 0 address -> otherwise: reverts
    ///     SIG3. `extensionRegistry` is not address(0)
    /// This function can approve an operator to cancel claims given:
    ///     AC1: 0 < `approvalCount` < type(uint64).max -> otherwise reverts
    /// This function can revoke an operator's approval to cancel claims given:
    ///     RC1: approvalCount == 0
    ///
    ///     RES1: approvalCount is stored
    ///     RES2: the nonce is incremented
    ///     RES3: the CancelClaimApproved event is emitted
    function permitCancelClaim(
        Approvals storage approvals,
        BullaExtensionRegistry extensionRegistry,
        bytes32 domainSeparator,
        address user,
        address operator,
        uint64 approvalCount,
        Signature calldata signature
    ) public {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                getPermitCancelClaimDigest(
                    extensionRegistry, user, operator, approvalCount, approvals.cancelClaim.nonce
                )
            )
        );

        if (!_validateSignature(user, digest, signature)) revert BullaClaim.InvalidSignature();

        approvals.cancelClaim.approvalCount = approvalCount;
        approvals.cancelClaim.nonce++;

        emit CancelClaimApproved(user, operator, approvalCount);
    }
}
