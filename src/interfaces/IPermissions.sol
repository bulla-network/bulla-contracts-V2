// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IPermissions
 * @dev Interface for permission management contracts
 */
interface IPermissions is IERC165 {
    /**
     * @dev Emitted when access is granted to an account
     */
    event AccessGranted(address indexed _account);

    /**
     * @dev Emitted when access is revoked from an account
     */
    event AccessRevoked(address indexed _account);

    /**
     * @dev Check if an address is allowed/has permission
     * @param _address The address to check
     * @return bool True if the address is allowed, false otherwise
     */
    function isAllowed(address _address) external view returns (bool);
}
