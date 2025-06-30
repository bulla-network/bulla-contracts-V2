// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./interfaces/IBullaClaim.sol";
import "./types/Types.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

abstract contract BullaClaimControllerBase is IERC721 {
    IBullaClaim public immutable _bullaClaim;

    constructor(address bullaClaimAddress) {
        _bullaClaim = IBullaClaim(bullaClaimAddress);
    }

    function _checkController(address controller) internal view {
        if (controller != address(this)) {
            revert IBullaClaim.NotController(msg.sender);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            ERC721 DELEGATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Transfers a controlled claim from one address to another
     * @notice Only the controller can initiate transfers for controlled claims
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param tokenId The claim ID to transfer
     */
    function transferFrom(address from, address to, uint256 tokenId) external virtual override {
        Claim memory claim = _bullaClaim.getClaim(tokenId);
        _checkController(claim.controller);

        // Controllers can implement custom logic here before delegation
        _beforeTokenTransfer(from, to, tokenId);

        // Delegate to BullaClaim using transferFromFrom - this allows the controller to act on behalf of the user
        _bullaClaim.transferFromFrom(msg.sender, from, to, tokenId);

        // Controllers can implement custom logic here after delegation
        _afterTokenTransfer(from, to, tokenId);
    }

    /**
     * @dev Safely transfers a controlled claim from one address to another
     * @notice Only the controller can initiate safe transfers for controlled claims
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param tokenId The claim ID to transfer
     */
    function safeTransferFrom(address from, address to, uint256 tokenId) external virtual override {
        safeTransferFrom(from, to, tokenId, "");
    }

    /**
     * @dev Safely transfers a controlled claim from one address to another with data
     * @notice Only the controller can initiate safe transfers for controlled claims
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param tokenId The claim ID to transfer
     * @param data Additional data to pass to the receiver
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual override {
        Claim memory claim = _bullaClaim.getClaim(tokenId);
        _checkController(claim.controller);

        // Controllers can implement custom logic here before delegation
        _beforeTokenTransfer(from, to, tokenId);

        // Delegate to BullaClaim using safeTransferFromFrom - this allows the controller to act on behalf of the user
        _bullaClaim.safeTransferFromFrom(msg.sender, from, to, tokenId, data);

        // Controllers can implement custom logic here after delegation
        _afterTokenTransfer(from, to, tokenId);
    }

    /**
     * @dev Approves another address to transfer a specific controlled claim
     * @notice Only the controller can set approvals for controlled claims
     * @param to The address to approve
     * @param tokenId The claim ID to approve
     */
    function approve(address to, uint256 tokenId) external virtual override {
        Claim memory claim = _bullaClaim.getClaim(tokenId);
        _checkController(claim.controller);

        // Controllers can implement custom logic here before delegation
        _beforeApproval(to, tokenId);

        // Delegate to BullaClaim using approveFrom - this allows the controller to act on behalf of the user
        _bullaClaim.approveFrom(msg.sender, to, tokenId);

        // Controllers can implement custom logic here after delegation
        _afterApproval(to, tokenId);
    }

    /**
     * @dev Sets or unsets approval for all controlled claims owned by the caller
     * @notice Only the controller can set operator approvals for users with controlled claims
     * @param operator The address to set approval for
     * @param approved Whether to approve or revoke approval
     */
    function setApprovalForAll(address operator, bool approved) external virtual override {
        // Note: This affects all tokens owned by msg.sender, so we need to check if they have any controlled claims
        // For simplicity, we'll delegate and let the underlying contract handle it
        // Controllers can override this function to implement more sophisticated logic

        // Controllers can implement custom logic here before delegation
        _beforeSetApprovalForAll(operator, approved);

        // Delegate to BullaClaim
        _bullaClaim.setApprovalForAll(operator, approved);

        // Controllers can implement custom logic here after delegation
        _afterSetApprovalForAll(operator, approved);
    }

    /*///////////////////////////////////////////////////////////////
                            ERC721 VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the number of tokens owned by an address
     * @param owner The address to query
     * @return The number of tokens owned
     */
    function balanceOf(address owner) external view override returns (uint256) {
        return _bullaClaim.balanceOf(owner);
    }

    /**
     * @dev Returns the owner of a token
     * @param tokenId The token ID to query
     * @return The owner address
     */
    function ownerOf(uint256 tokenId) external view override returns (address) {
        return _bullaClaim.ownerOf(tokenId);
    }

    /**
     * @dev Returns the approved address for a token
     * @param tokenId The token ID to query
     * @return The approved address
     */
    function getApproved(uint256 tokenId) external view override returns (address) {
        return _bullaClaim.getApproved(tokenId);
    }

    /**
     * @dev Returns whether an operator is approved for all tokens of an owner
     * @param owner The owner address
     * @param operator The operator address
     * @return Whether the operator is approved
     */
    function isApprovedForAll(address owner, address operator) external view override returns (bool) {
        return _bullaClaim.isApprovedForAll(owner, operator);
    }

    /*///////////////////////////////////////////////////////////////
                            ERC165 SUPPORT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Internal function to check if this contract supports ERC721
     * @notice Concrete contracts should override supportsInterface to include this check
     * @param interfaceId The interface identifier
     * @return True if the interface is ERC721
     */
    function _supportsERC721Interface(bytes4 interfaceId) internal pure returns (bool) {
        return interfaceId == type(IERC721).interfaceId;
    }

    /*///////////////////////////////////////////////////////////////
                            HOOK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Hook called before token transfers
     * @notice Controllers can override this to implement custom logic
     * @param from The address transferring from
     * @param to The address transferring to
     * @param tokenId The token being transferred
     */
    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual {
        // Default implementation does nothing
        // Controllers can override to add custom logic (e.g., transfer fees, restrictions)
    }

    /**
     * @dev Hook called after token transfers
     * @notice Controllers can override this to implement custom logic
     * @param from The address transferring from
     * @param to The address transferring to
     * @param tokenId The token being transferred
     */
    function _afterTokenTransfer(address from, address to, uint256 tokenId) internal virtual {
        // Default implementation does nothing
        // Controllers can override to add custom logic (e.g., notifications, state updates)
    }

    /**
     * @dev Hook called before token approvals
     * @notice Controllers can override this to implement custom logic
     * @param to The address being approved
     * @param tokenId The token being approved
     */
    function _beforeApproval(address to, uint256 tokenId) internal virtual {
        // Default implementation does nothing
        // Controllers can override to add custom logic
    }

    /**
     * @dev Hook called after token approvals
     * @notice Controllers can override this to implement custom logic
     * @param to The address being approved
     * @param tokenId The token being approved
     */
    function _afterApproval(address to, uint256 tokenId) internal virtual {
        // Default implementation does nothing
        // Controllers can override to add custom logic
    }

    /**
     * @dev Hook called before setting approval for all
     * @notice Controllers can override this to implement custom logic
     * @param operator The operator address
     * @param approved Whether approval is being granted or revoked
     */
    function _beforeSetApprovalForAll(address operator, bool approved) internal virtual {
        // Default implementation does nothing
        // Controllers can override to add custom logic
    }

    /**
     * @dev Hook called after setting approval for all
     * @notice Controllers can override this to implement custom logic
     * @param operator The operator address
     * @param approved Whether approval is being granted or revoked
     */
    function _afterSetApprovalForAll(address operator, bool approved) internal virtual {
        // Default implementation does nothing
        // Controllers can override to add custom logic
    }
}
