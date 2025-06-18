// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import "./interfaces/IPermissions.sol";

/**
 * @title Permissions
 * @dev Abstract base contract for permission management with ERC165 support
 */
abstract contract Permissions is IPermissions, ERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IPermissions).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IPermissions-isAllowed}.
     */
    function isAllowed(address _address) external view virtual returns (bool);
}
