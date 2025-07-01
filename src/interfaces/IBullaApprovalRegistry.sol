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
    error InvalidSignature();

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

    event ContractAuthorized(address indexed contractAddress, bool authorized);

    /*///////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getApprovals(address user, address controller)
        external
        view
        returns (CreateClaimApproval memory createClaim);

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

    /*///////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setAuthorizedContract(address contractAddress, bool authorized) external;

    function setControllerRegistry(address controllerRegistry) external;
}
