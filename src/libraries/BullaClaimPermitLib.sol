// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "../types/Types.sol";
import "../interfaces/IBullaControllerRegistry.sol";
import "../interfaces/IBullaApprovalRegistry.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

library BullaClaimPermitLib {
    using Strings for uint256;
    using Strings for address;

    bytes32 constant CREATE_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCreateClaimExtension(address user,address controller,string message,uint8 approvalType,uint256 approvalCount,bool isBindingAllowed,uint256 nonce)"
        )
    );

    bytes32 constant CLAIM_PAYMENT_APPROVAL_TYPEHASH =
        keccak256(bytes("ClaimPaymentApproval(uint256 claimId,uint256 approvalDeadline,uint256 approvedAmount)"));

    bytes32 constant PAY_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApprovePayClaimExtension(address user,address controller,string message,uint8 approvalType,uint256 approvalDeadline,ClaimPaymentApproval[] paymentApprovals,uint256 nonce)ClaimPaymentApproval(uint256 claimId,uint256 approvalDeadline,uint256 approvedAmount)"
        )
    );

    bytes32 constant CANCEL_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveCancelClaimExtension(address user,address controller,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    bytes32 constant UPDATE_BINDING_TYPEHASH = keccak256(
        bytes(
            "ApproveUpdateBindingExtension(address user,address controller,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    bytes32 constant IMPAIR_CLAIM_TYPEHASH = keccak256(
        bytes(
            "ApproveImpairClaimExtension(address user,address controller,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    bytes32 constant MARK_AS_PAID_TYPEHASH = keccak256(
        bytes(
            "ApproveMarkAsPaidExtension(address user,address controller,string message,uint256 approvalCount,uint256 nonce)"
        )
    );

    /*
    ////// PERMIT MESSAGES //////
    */

    function getPermitCreateClaimMessage(
        IBullaControllerRegistry controllerRegistry,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (string memory) {
        return approvalCount > 0 // approve case:
            ? string.concat(
                "I approve the following contract: ", // todo: add \n new lines
                controllerRegistry.getControllerName(controller),
                " (",
                controller.toHexString(), // note: will _not_ be checksummed
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
                controllerRegistry.getControllerName(controller),
                " (",
                controller.toHexString(),
                ") ",
                "to create claims on my behalf."
            );
    }

    /*
    ////// PERMIT DIGEST FUNCTIONS //////
    */

    function getPermitCreateClaimDigest(
        IBullaControllerRegistry controllerRegistry,
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        uint64 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                CREATE_CLAIM_TYPEHASH,
                user,
                controller, // spec.S3
                keccak256(
                    bytes(
                        getPermitCreateClaimMessage(
                            controllerRegistry, controller, approvalType, approvalCount, isBindingAllowed
                        )
                    )
                ),
                approvalType,
                approvalCount,
                isBindingAllowed,
                nonce
            )
        );
    }

    /*///////////////////////////////////////////////////////////////
                       PERMIT LOGIC FOR BULLA CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice allows a user - via a signature - to appove an controller to call createClaim on their behalf
    /// @notice SPEC:
    /// Anyone can call this function with a valid signature to modify the `user`'s CreateClaimApproval of `controller` to the provided arguments
    /// In all cases:
    ///     SIG1: The recovered signer from the EIP712 signature == `user`
    ///     SIG2: `user` is not a 0 address
    ///     SIG3: `controllerRegistry` is not address(0)
    /// This function can _approve_ a controller given:
    ///     A1: approvalType is either CreditorOnly, DebtorOnly, or Approved
    ///     A2: 0 < `approvalCount` < type(uint64).max -> otherwise: reverts
    ///
    ///     A.RES1: The nonce is incremented
    ///     A.RES2: the isBindingAllowed argument is stored
    ///     A.RES3: the approvalType argument is stored
    ///     A.RES4: the approvalCount argument is stored
    /// This function can _revoke_ a controller given:
    ///     R1: approvalType is Unapproved
    ///     R2: `approvalCount` == 0 -> otherwise: reverts
    ///     R3: `isBindingAllowed` == false -> otherwise: reverts
    ///
    ///     R.RES1: The nonce is incremented
    ///     R.RES2: the isBindingAllowed argument is deleted
    ///     R.RES3: the approvalType argument is set to unapproved
    ///     R.RES4: the approvalCount argument is deleted
    ///
    /// A valid approval signature is defined as: a signed EIP712 hash digest of the following arguments:
    ///     S1: The hash of the EIP712 typedef string
    ///     S2: The `user` address
    ///     S3: The `controller` address
    ///     S4: A verbose approval message: see `BullaClaimPermitLib.getPermitCreateClaimMessage()`
    ///     S5: The `approvalType` enum as a uint8
    ///     S6: The `approvalCount`
    ///     S7: The `isBindingAllowed` boolean flag
    ///     S8: The stored signing nonce found in `user`'s CreateClaimApproval struct for `controller`
    function permitCreateClaim(
        Approvals storage approvals,
        IBullaControllerRegistry controllerRegistry,
        bytes32 domainSeparator,
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        bytes calldata signature
    ) public {
        uint64 nonce = approvals.createClaim.nonce;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                getPermitCreateClaimDigest(
                    controllerRegistry, user, controller, approvalType, approvalCount, isBindingAllowed, nonce
                )
            )
        );

        if (
            !SignatureChecker.isValidSignatureNow(user, digest, signature) // spec.SIG1, spec.SIG2
        ) revert IBullaApprovalRegistry.InvalidSignature();

        if (approvalType == CreateClaimApprovalType.Unapproved) {
            if (approvalCount > 0 || isBindingAllowed) revert IBullaApprovalRegistry.InvalidApproval(); // spec.R2, spec.R3

            approvals.createClaim.nonce++; // spec.R.RES1
            delete approvals.createClaim.isBindingAllowed; // spec.R.RES2
            delete approvals.createClaim.approvalType; // spec.R.RES3
            delete approvals.createClaim.approvalCount; // spec.R.RES4
        } else {
            // spec.A1
            if (approvalCount == 0) revert IBullaApprovalRegistry.InvalidApproval(); // spec.A2

            approvals.createClaim.nonce++; // spec.A.RES1
            approvals.createClaim.isBindingAllowed = isBindingAllowed; // spec.A.RES2
            approvals.createClaim.approvalType = approvalType; // spec.A.RES3
            approvals.createClaim.approvalCount = approvalCount; // spec.A.RES4
        }

        // spec.RES3
        emit IBullaApprovalRegistry.CreateClaimApproved(user, controller, approvalType, approvalCount, isBindingAllowed);
    }
}
