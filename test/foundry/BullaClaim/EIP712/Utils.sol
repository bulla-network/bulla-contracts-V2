// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import "contracts/types/Types.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "contracts/BullaClaim.sol";

address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

function privateKeyValidity(uint256 pk) pure returns (bool) {
    return pk != 0 && pk < 115792089237316195423570985008687907852837564279074904382605163141518161494337;
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
        CREATE_CLAIM_TYPEHASH = BullaClaimEIP712.CREATE_CLAIM_TYPEHASH;
    }

    function _hashPermitCreateClaim(
        address owner,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) internal view returns (bytes32) {
        (CreateClaimApproval memory approvals,) = bullaClaim.approvals(owner, operator);

        return keccak256(
            abi.encode(
                CREATE_CLAIM_TYPEHASH,
                owner,
                operator,
                keccak256(
                    bytes(
                        BullaClaimEIP712.getPermitCreateClaimMessage(
                            bullaClaim.extensionRegistry(), operator, approvalType, approvalCount, isBindingAllowed
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
        address owner,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashPermitCreateClaim(owner, operator, approvalType, approvalCount, isBindingAllowed)
            )
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getPermitPayClaimDigest(
        address owner,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals
    ) public view returns (bytes32) {
        (, PayClaimApproval memory approval) = bullaClaim.approvals(owner, operator);
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                BullaClaimEIP712.getPermitPayClaimDigest(
                    bullaClaim.extensionRegistry(),
                    owner,
                    operator,
                    approvalType,
                    approvalDeadline,
                    paymentApprovals,
                    approval.nonce
                )
            )
        );
    }

    function signCreateClaimPermit(
        uint256 pk,
        address owner,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public returns (Signature memory) {
        bytes32 digest = getPermitCreateClaimDigest(owner, operator, approvalType, approvalCount, isBindingAllowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Signature({v: v, r: r, s: s});
    }

    function signPayClaimPermit(
        uint256 pk,
        address owner,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals
    ) public returns (Signature memory) {
        bytes32 digest = getPermitPayClaimDigest(owner, operator, approvalType, approvalDeadline, paymentApprovals);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Signature({v: v, r: r, s: s});
    }
}
