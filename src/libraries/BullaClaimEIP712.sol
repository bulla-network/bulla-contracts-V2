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

    function getPermitPayClaimMessageDigest(
        BullaExtensionRegistry extensionRegistry,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline
    ) public view returns (bytes32) {
        return keccak256(bytes(getPermitPayClaimMessage(extensionRegistry, operator, approvalType, approvalDeadline)));
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
                getPermitPayClaimMessageDigest(extensionRegistry, operator, approvalType, approvalDeadline),
                approvalType,
                approvalDeadline,
                hashPaymentApprovals(paymentApprovals),
                nonce
            )
        );
    }

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
}
