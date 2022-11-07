// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {BullaExtensionRegistry} from "contracts/BullaExtensionRegistry.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

library BullaClaimEIP712 {
    using Strings for uint256;
    using Strings for address;

    bytes32 constant CREATE_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCreateClaimExtension(address owner,address operator,string message,uint8 approvalType,uint256 approvalCount,bool isBindingAllowed,uint256 nonce)"
        )
    );

    bytes32 constant CLAIM_PAYMENT_APPROVAL_TYPEHASH =
        keccak256(bytes("ClaimPaymentApproval(uint256 claimId,uint256 approvalDeadline,uint256 approvedAmount)"));

    bytes32 constant PAY_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApprovePayClaimExtension(address owner,address operator,string message,uint8 approvalType,uint256 approvalDeadline,ClaimPaymentApproval[] paymentApprovals,uint256 nonce)ClaimPaymentApproval(uint256 claimId,uint256 approvalDeadline,uint256 approvedAmount)"
        )
    );

    bytes32 constant CANCEL_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCancelClaimExtension(address owner,address operator,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    bytes32 constant UPDATE_BINDING_TYPEHASH = keccak256(
        bytes(
            "ApproveUpdateBindingExtension(address owner,address operator,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

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

    function getPermitCreateClaimDigest(
        BullaExtensionRegistry extensionRegistry,
        address owner,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BullaClaimEIP712.CREATE_CLAIM_TYPEHASH, // spec.S1
                owner, // spec.S2
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
                    BullaClaimEIP712.CLAIM_PAYMENT_APPROVAL_TYPEHASH,
                    paymentApprovals[i].claimId,
                    paymentApprovals[i].approvalDeadline,
                    paymentApprovals[i].approvedAmount
                )
            );
        }
        return keccak256(abi.encodePacked(approvalHashes));
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

    function getPermitPayClaimDigest(
        BullaExtensionRegistry extensionRegistry,
        address owner,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals,
        uint256 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                PAY_CLAIM_TYPEHASH,
                owner,
                operator,
                keccak256(bytes(getPermitPayClaimMessage(extensionRegistry, operator, approvalType, approvalDeadline))),
                approvalType,
                approvalDeadline,
                hashPaymentApprovals(paymentApprovals),
                nonce
            )
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

    function getPermitCancelClaimDigest(
        BullaExtensionRegistry extensionRegistry,
        address owner,
        address operator,
        uint64 approvalCount,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BullaClaimEIP712.CANCEL_CLAIM_TYPEHASH,
                owner,
                operator,
                keccak256(bytes(getPermitCancelClaimMessage(extensionRegistry, operator, approvalCount))),
                approvalCount,
                nonce
            )
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

    function getPermitUpdateBindingDigest(
        BullaExtensionRegistry extensionRegistry,
        address owner,
        address operator,
        uint64 approvalCount,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BullaClaimEIP712.UPDATE_BINDING_TYPEHASH,
                owner,
                operator,
                keccak256(bytes(getPermitUpdateBindingMessage(extensionRegistry, operator, approvalCount))),
                approvalCount,
                nonce
            )
        );
    }
}
