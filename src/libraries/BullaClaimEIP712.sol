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
