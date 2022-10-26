// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {BullaExtensionRegistry} from "contracts/BullaExtensionRegistry.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {console} from "forge-std/console.sol";

library BullaClaimEIP712 {
    using Strings for uint256;
    using Strings for address;

    bytes32 constant CREATE_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCreateClaimExtension(address owner,address operator,string message,uint8 approvalType,uint256 approvalCount,bool isBindingAllowed,uint256 nonce)"
        )
    );

    bytes32 constant CLAIM_PAYMENT_APPROVAL_TYPEHASH = keccak256(
        bytes("ClaimPaymentApproval(uint256 claimId,uint256 approvalExpiraryTimestamp,uint256 approvedAmount)")
    );

    bytes32 constant PAY_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApprovePayClaimExtension(address owner,address operator,string message,uint8 approvalType,uint256 approvalExpiraryTimestamp,ClaimPaymentApproval[] paymentApprovals,uint256 nonce)ClaimPaymentApproval(uint256 claimId,uint256 approvalExpiraryTimestamp,uint256 approvedAmount)"
        )
    );

    function hashPaymentApprovals(ClaimPaymentApproval[] calldata paymentApprovals) public pure returns (bytes32) {
        bytes32[] memory approvalHashes = new bytes32[](
            paymentApprovals.length
        );
        for (uint256 i; i < paymentApprovals.length; ++i) {
            approvalHashes[i] = keccak256(
                abi.encode(
                    BullaClaimEIP712.CLAIM_PAYMENT_APPROVAL_TYPEHASH,
                    paymentApprovals[i].claimId,
                    paymentApprovals[i].approvalExpiraryTimestamp,
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
        uint40 approvalExpiraryTimestamp
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
                approvalExpiraryTimestamp != 0
                    ? string.concat(" until the timestamp: ", uint256(approvalExpiraryTimestamp).toString())
                    : "."
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
        uint40 approvalExpiraryTimestamp
    ) public view returns (bytes32) {
        return keccak256(
            bytes(getPermitPayClaimMessage(extensionRegistry, operator, approvalType, approvalExpiraryTimestamp))
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

    function getPermitCreateClaimMessageDigest(
        BullaExtensionRegistry extensionRegistry,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (bytes32) {
        return keccak256(
            bytes(
                getPermitCreateClaimMessage(extensionRegistry, operator, approvalType, approvalCount, isBindingAllowed)
            )
        );
    }
}
