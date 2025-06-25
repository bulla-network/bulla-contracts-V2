// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "../types/Types.sol";
import "./IBullaControllerRegistry.sol";

interface IBullaApprovalRegistry {
    /*///////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error InvalidApproval();
    error PaymentUnderApproved();
    error ApprovalExpired();
    error PastApprovalDeadline();

    /*///////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event CreateClaimApproved(
        address indexed user,
        address indexed controller,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    event PayClaimApproved(
        address indexed user,
        address indexed controller,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] paymentApprovals
    );

    event UpdateBindingApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event CancelClaimApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event ImpairClaimApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event MarkAsPaidApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event ContractAuthorized(address indexed contractAddress, bool authorized);

    /*///////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getApprovals(address user, address controller)
        external
        view
        returns (
            CreateClaimApproval memory createClaim,
            PayClaimApproval memory payClaim,
            UpdateBindingApproval memory updateBinding,
            CancelClaimApproval memory cancelClaim,
            ImpairClaimApproval memory impairClaim,
            MarkAsPaidApproval memory markAsPaid
        );

    function isAuthorizedContract(address contractAddress) external view returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function controllerRegistry() external view returns (IBullaControllerRegistry);

    /*///////////////////////////////////////////////////////////////
                        APPROVAL SPENDING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function spendCreateClaimApproval(
        address user,
        address controller,
        address creditor,
        address debtor,
        ClaimBinding binding
    ) external;

    function spendPayClaimApproval(address user, address controller, uint256 claimId, uint256 amount) external;

    function spendUpdateBindingApproval(address user, address controller) external;

    function spendCancelClaimApproval(address user, address controller) external;

    function spendImpairClaimApproval(address user, address controller) external;

    function spendMarkAsPaidApproval(address user, address controller) external;

    /*///////////////////////////////////////////////////////////////
                        PERMIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function permitCreateClaim(
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        bytes memory signature
    ) external;

    function permitPayClaim(
        address user,
        address controller,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] memory paymentApprovals,
        bytes memory signature
    ) external;

    function permitUpdateBinding(address user, address controller, uint64 approvalCount, bytes memory signature)
        external;

    function permitCancelClaim(address user, address controller, uint64 approvalCount, bytes memory signature)
        external;

    function permitImpairClaim(address user, address controller, uint64 approvalCount, bytes memory signature)
        external;

    function permitMarkAsPaid(address user, address controller, uint64 approvalCount, bytes memory signature)
        external;

    /*///////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setAuthorizedContract(address contractAddress, bool authorized) external;

    function setControllerRegistry(address controllerRegistry) external;
}
