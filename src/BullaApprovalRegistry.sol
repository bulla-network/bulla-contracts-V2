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
        returns (
            CreateClaimApproval memory createClaim,
            PayClaimApproval memory payClaim,
            UpdateBindingApproval memory updateBinding,
            CancelClaimApproval memory cancelClaim,
            ImpairClaimApproval memory impairClaim,
            MarkAsPaidApproval memory markAsPaid
        )
    {
        Approvals storage userApprovals = approvals[user][controller];
        return (
            userApprovals.createClaim,
            userApprovals.payClaim,
            userApprovals.updateBinding,
            userApprovals.cancelClaim,
            userApprovals.impairClaim,
            userApprovals.markAsPaid
        );
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

    function spendPayClaimApproval(address user, address controller, uint256 claimId, uint256 amount)
        external
        onlyAuthorized
    {
        PayClaimApproval storage approval = approvals[user][controller].payClaim;

        // Use validation library for approval validation
        (uint256 _approvalIndex,) = BullaClaimValidationLib.validatePayClaimApproval(approval, claimId, amount);

        // If approved for all, no storage updates needed
        if (approval.approvalType == PayClaimApprovalType.IsApprovedForAll) return;

        // Handle specific approval spending
        uint256 i = _approvalIndex;
        if (amount == approval.claimApprovals[i].approvedAmount) {
            // Approval is fully spent, remove it
            uint256 totalApprovals = approval.claimApprovals.length;
            if (i != totalApprovals - 1) {
                approval.claimApprovals[i] = approval.claimApprovals[totalApprovals - 1];
            }
            approval.claimApprovals.pop();
        } else {
            // Partially spend the approval
            approval.claimApprovals[i].approvedAmount -= uint128(amount);
        }
    }

    function spendUpdateBindingApproval(address user, address controller) external onlyAuthorized {
        UpdateBindingApproval storage approval = approvals[user][controller].updateBinding;

        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;
    }

    function spendCancelClaimApproval(address user, address controller) external onlyAuthorized {
        CancelClaimApproval storage approval = approvals[user][controller].cancelClaim;

        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;
    }

    function spendImpairClaimApproval(address user, address controller) external onlyAuthorized {
        ImpairClaimApproval storage approval = approvals[user][controller].impairClaim;

        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;
    }

    function spendMarkAsPaidApproval(address user, address controller) external onlyAuthorized {
        MarkAsPaidApproval storage approval = approvals[user][controller].markAsPaid;

        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;
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

    function permitPayClaim(
        address user,
        address controller,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] memory paymentApprovals,
        bytes memory signature
    ) external {
        BullaClaimPermitLib.permitPayClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalType,
            approvalDeadline,
            paymentApprovals,
            signature
        );
    }

    function permitUpdateBinding(address user, address controller, uint64 approvalCount, bytes memory signature)
        external
    {
        BullaClaimPermitLib.permitUpdateBinding(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    function permitCancelClaim(address user, address controller, uint64 approvalCount, bytes memory signature)
        external
    {
        BullaClaimPermitLib.permitCancelClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    function permitImpairClaim(address user, address controller, uint64 approvalCount, bytes memory signature)
        external
    {
        BullaClaimPermitLib.permitImpairClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    function permitMarkAsPaid(address user, address controller, uint64 approvalCount, bytes memory signature)
        external
    {
        BullaClaimPermitLib.permitMarkAsPaid(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
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
