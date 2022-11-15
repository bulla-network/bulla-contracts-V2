//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "contracts/interfaces/IBullaClaim.sol";

enum PermitType {
    CreateClaim,
    PayClaim,
    UpdateBinding,
    CancelClaim
}

struct Permit {
    PermitType permitType;
    address user;
    address operator;
    bytes permitData;
    bytes signature;
}

/// @dev a base contract that can forward multiple permits to BullaBanker in a single transaction
abstract contract BullaPermitter {
    IBullaClaim public bullaClaim;

    constructor(address _bullaClaim) {
        bullaClaim = IBullaClaim(_bullaClaim);
    }

    function permitCreateClaim(
        address user,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        bytes calldata signature
    ) public {
        bullaClaim.permitCreateClaim(user, operator, approvalType, approvalCount, isBindingAllowed, signature);
    }

    function permitPayClaim(
        address user,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals,
        bytes calldata signature
    ) public {
        bullaClaim.permitPayClaim(user, operator, approvalType, approvalDeadline, paymentApprovals, signature);
    }

    function permitUpdateBinding(address user, address operator, uint64 approvalCount, bytes calldata signature)
        public
    {
        bullaClaim.permitUpdateBinding(user, operator, approvalCount, signature);
    }

    function permitCancelClaim(address user, address operator, uint64 approvalCount, bytes calldata signature) public {
        bullaClaim.permitCancelClaim(user, operator, approvalCount, signature);
    }

    function batchPermit(Permit[] calldata permits) public {
        uint256 i;
        for (; i < permits.length; ++i) {
            if (permits[i].permitType == PermitType.CreateClaim) {
                (CreateClaimApprovalType approvalType, uint64 approvalCount, bool isBindingAllowed) =
                    abi.decode(permits[i].permitData, (CreateClaimApprovalType, uint64, bool));
                bullaClaim.permitCreateClaim(
                    permits[i].user,
                    permits[i].operator,
                    approvalType,
                    approvalCount,
                    isBindingAllowed,
                    permits[i].signature
                );
            } else if (permits[i].permitType == PermitType.PayClaim) {
                (
                    PayClaimApprovalType approvalType,
                    uint256 approvalDeadline,
                    ClaimPaymentApprovalParam[] memory paymentApprovals
                ) = abi.decode(permits[i].permitData, (PayClaimApprovalType, uint256, ClaimPaymentApprovalParam[]));
                bullaClaim.permitPayClaim(
                    permits[i].user,
                    permits[i].operator,
                    approvalType,
                    approvalDeadline,
                    paymentApprovals,
                    permits[i].signature
                );
            } else if (permits[i].permitType == PermitType.UpdateBinding) {
                uint64 approvalCount = abi.decode(permits[i].permitData, (uint64));
                bullaClaim.permitUpdateBinding(
                    permits[i].user, permits[i].operator, approvalCount, permits[i].signature
                );
            } else if (permits[i].permitType == PermitType.CancelClaim) {
                uint64 approvalCount = abi.decode(permits[i].permitData, (uint64));
                bullaClaim.permitCancelClaim(permits[i].user, permits[i].operator, approvalCount, permits[i].signature);
            }
        }
    }
}
