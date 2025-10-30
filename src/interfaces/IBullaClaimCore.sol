// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "../types/Types.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {IBullaControllerRegistry} from "./IBullaControllerRegistry.sol";
import {IBullaApprovalRegistry} from "./IBullaApprovalRegistry.sol";

interface IBullaClaimCore is IERC721 {
    /*///////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function approvalRegistry() external view returns (IBullaApprovalRegistry);

    function lockState() external view returns (LockState);

    function currentClaimId() external view returns (uint256);

    function getClaim(uint256 claimId) external view returns (Claim memory claim);

    function claimMetadata(uint256) external view returns (string memory tokenURI, string memory attachmentURI);

    function CORE_PROTOCOL_FEE() external view returns (uint256);

    /*///////////////////////////////////////////////////////////////
                        CORE CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createClaim(CreateClaimParams memory params) external payable returns (uint256);

    function createClaimFrom(address from, CreateClaimParams memory params) external payable returns (uint256);

    function createClaimWithMetadata(CreateClaimParams memory params, ClaimMetadata memory metadata)
        external
        payable
        returns (uint256);

    function createClaimWithMetadataFrom(address from, CreateClaimParams memory params, ClaimMetadata memory metadata)
        external
        payable
        returns (uint256);

    function payClaim(uint256 claimId, uint256 amount) external payable;

    function payClaimFrom(address from, uint256 claimId, uint256 amount) external payable;

    function payClaimFromControllerWithoutTransfer(address from, uint256 claimId, uint256 amount)
        external
        returns (bool claimPaid);

    function updateBinding(uint256 claimId, ClaimBinding binding) external;

    function updateBindingFrom(address from, uint256 claimId, ClaimBinding binding) external;

    function cancelClaim(uint256 claimId, string memory note) external;

    function cancelClaimFrom(address from, uint256 claimId, string memory note) external;

    function impairClaim(uint256 claimId) external;

    function impairClaimFrom(address from, uint256 claimId) external;

    function markClaimAsPaid(uint256 claimId) external;

    function markClaimAsPaidFrom(address from, uint256 claimId) external;

    /*///////////////////////////////////////////////////////////////
                        PAID CLAIM CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setPaidClaimCallback(uint256 claimId, address callbackContract, bytes4 callbackSelector) external;

    function setPaidClaimCallbackFrom(address from, uint256 claimId, address callbackContract, bytes4 callbackSelector)
        external;

    function getPaidClaimCallback(uint256 claimId) external view returns (PaidClaimCallback memory);

    function addToPaidCallbackWhitelist(address callbackContract, bytes4 selector) external;

    function removeFromPaidCallbackWhitelist(address callbackContract, bytes4 selector) external;

    function isPaidCallbackWhitelisted(address callbackContract, bytes4 selector) external view returns (bool);

    /*///////////////////////////////////////////////////////////////
                        ERC721 "FROM" FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function safeTransferFromFrom(
        address fromAkaOriginalMsgSender,
        address fromAkaNftOwner,
        address to,
        uint256 claimId,
        bytes memory data
    ) external;

    function transferFromFrom(address fromAkaOriginalMsgSender, address fromAkaNftOwner, address to, uint256 claimId)
        external;

    function approveFrom(address from, address to, uint256 claimId) external;
}
