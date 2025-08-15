// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./interfaces/IBullaApprovalRegistry.sol";
import "./types/Types.sol";
import "./interfaces/IBullaControllerRegistry.sol";
import "./libraries/BullaClaimPermitLib.sol";
import "./libraries/BullaClaimValidationLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract BullaApprovalRegistry is IBullaApprovalRegistry, Ownable, EIP712 {
    /*///////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// a mapping of users to controllers to approvals for specific actions
    mapping(address => mapping(address => Approvals)) public approvals;

    /// mapping of contracts authorized to spend approvals
    mapping(address => bool) public authorizedContracts;

    /// controller registry for permit validation
    IBullaControllerRegistry public controllerRegistry;

    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAuthorized() {
        if (!authorizedContracts[msg.sender]) revert NotAuthorized();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _controllerRegistry) EIP712("BullaApprovalRegistry", "1") Ownable(msg.sender) {
        controllerRegistry = IBullaControllerRegistry(_controllerRegistry);
    }

    /*///////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getApprovals(address user, address controller)
        external
        view
        returns (CreateClaimApproval memory createClaim)
    {
        Approvals storage userApprovals = approvals[user][controller];
        return userApprovals.createClaim;
    }

    function isAuthorizedContract(address contractAddress) external view returns (bool) {
        return authorizedContracts[contractAddress];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*///////////////////////////////////////////////////////////////
                        APPROVAL SPENDING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function spendCreateClaimApproval(
        address user,
        address controller,
        address creditor,
        address debtor,
        ClaimBinding binding
    ) external onlyAuthorized {
        CreateClaimApproval memory approval = approvals[user][controller].createClaim;

        // Use validation library for approval validation
        BullaClaimValidationLib.validateCreateClaimApproval(approval, user, creditor, debtor, binding);

        if (approval.approvalCount != type(uint64).max) {
            if (approval.approvalCount == 1) {
                approvals[user][controller].createClaim.approvalType = CreateClaimApprovalType.Unapproved;
            }
            approvals[user][controller].createClaim.approvalCount -= 1;
        }
    }

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
    ) external {
        BullaClaimPermitLib.permitCreateClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalType,
            approvalCount,
            isBindingAllowed,
            signature
        );
    }

    /*///////////////////////////////////////////////////////////////
                        APPROVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function approveCreateClaim(
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) external {
        BullaClaimPermitLib.approveCreateClaim(
            approvals[msg.sender][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            msg.sender,
            controller,
            approvalType,
            approvalCount,
            isBindingAllowed
        );
    }

    /*///////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setAuthorizedContract(address contractAddress, bool authorized) external onlyOwner {
        authorizedContracts[contractAddress] = authorized;
        emit ContractAuthorized(contractAddress, authorized);
    }

    function setControllerRegistry(address _controllerRegistry) external onlyOwner {
        controllerRegistry = IBullaControllerRegistry(_controllerRegistry);
    }
}
