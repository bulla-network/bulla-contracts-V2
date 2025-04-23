// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import "contracts/BullaExtensionRegistry.sol";
import {IERC721} from "openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";

interface IBullaClaim {
    //// ERRORS / MODIFIERS ////

    error Locked();
    error CannotBindClaim();
    error InvalidApproval();
    error InvalidSignature();
    error InvalidTimestamp();
    error PastApprovalDeadline();
    error NotOwner();
    error NotCreditorOrDebtor();
    error NotController(address sender);
    error ClaimBound();
    error ClaimNotPending();
    error ClaimPending();
    error NotMinted();
    error NotApproved();
    error PayingZero();
    error PaymentUnderApproved();
    error OverPaying(uint256 paymentAmount);

    //// EVENTS ////

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        uint256 dueBy,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    event MetadataAdded(uint256 indexed claimId, string tokenURI, string attachmentURI);

    event ClaimPayment(
        uint256 indexed claimId,
        address indexed paidBy,
        uint256 paymentAmount,
        uint256 totalPaidAmount
    );

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

    event ClaimRejected(uint256 indexed claimId, address indexed from, string note);

    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    event CreateClaimApproved(
        address indexed user,
        address indexed operator,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    event PayClaimApproved(
        address indexed user,
        address indexed operator,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] paymentApprovals
    );

    event UpdateBindingApproved(address indexed user, address indexed operator, uint256 approvalCount);

    event CancelClaimApproved(address indexed user, address indexed operator, uint256 approvalCount);

    //// ERC721 ////

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function balanceOf(address owner) external view returns (uint256);

    function ownerOf(uint256 id) external view returns (address owner);

    function approve(address spender, uint256 id) external;

    function getApproved(uint256) external view returns (address);

    function setApprovalForAll(address operator, bool approved) external;

    function isApprovedForAll(address, address) external view returns (bool);

    function safeTransferFrom(address from, address to, uint256 id) external;

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) external;

    function transferFrom(address from, address to, uint256 id) external;

    function tokenURI(uint256 _claimId) external view returns (string memory);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    //// BULLA CLAIM ////

    function DOMAIN_SEPARATOR() external view returns (bytes32);


    function extensionRegistry() external view returns (address);

    function owner() external view returns (address);

    function lockState() external view returns (LockState);

    function currentClaimId() external view returns (uint256);

    function getClaim(uint256 claimId) external view returns (Claim memory claim);

    function claimMetadata(uint256) external view returns (string memory tokenURI, string memory attachmentURI);

    function approvals(address, address)
        external
        view
        returns (
            CreateClaimApproval memory createClaim,
            PayClaimApproval memory payClaim,
            CancelClaimApproval memory updateBinding,
            CancelClaimApproval memory cancelClaim
        );

    function createClaim(CreateClaimParams memory params) external returns (uint256);

    function createClaimFrom(address from, CreateClaimParams memory params) external returns (uint256);

    function createClaimWithMetadata(CreateClaimParams memory params, ClaimMetadata memory metadata)
        external
        returns (uint256);

    function createClaimWithMetadataFrom(address from, CreateClaimParams memory params, ClaimMetadata memory metadata)
        external
        returns (uint256);

    function payClaim(uint256 claimId, uint256 amount) external payable;

    function payClaimFrom(address from, uint256 claimId, uint256 amount) external payable;

    function updateBinding(uint256 claimId, uint8 binding) external;

    function updateBindingFrom(address from, uint256 claimId, uint8 binding) external;

    function cancelClaim(uint256 claimId, string memory note) external;

    function cancelClaimFrom(address from, uint256 claimId, string memory note) external;

    function burn(uint256 tokenId) external;

    function permitCreateClaim(
        address user,
        address operator,
        uint8 approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        bytes memory signature
    ) external;

    function permitPayClaim(
        address user,
        address operator,
        uint8 approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] memory paymentApprovals,
        bytes memory signature
    ) external;

    function permitUpdateBinding(address user, address operator, uint64 approvalCount, bytes memory signature)
        external;

    function permitCancelClaim(address user, address operator, uint64 approvalCount, bytes memory signature) external;

    // ADMIN FUNCTIONS //
    function transferOwnership(address newOwner) external;

    function renounceOwnership() external;

    function setExtensionRegistry(address _extensionRegistry) external;


    function setLockState(uint8 _lockState) external;

    // UTILITY FUNCTIONS //
    function permitToken(
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function batch(bytes[] memory calls, bool revertOnFail) external payable;
}
