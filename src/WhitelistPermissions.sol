// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import "./Permissions.sol";

/**
 * @title WhitelistPermissions
 * @dev A whitelist-based permissions contract with ERC165 support
 */
contract WhitelistPermissions is Permissions, Ownable {
    mapping(address => bool) private allowedAddresses;

    constructor() Ownable(msg.sender) {}

    /**
     * @dev See {IPermissions-isAllowed}.
     */
    function isAllowed(address _address) external view override returns (bool) {
        return allowedAddresses[_address];
    }

    /**
     * @dev Add an address to the whitelist
     * @param _address The address to allow
     */
    function allow(address _address) public onlyOwner {
        allowedAddresses[_address] = true;
        emit AccessGranted(_address);
    }

    /**
     * @dev Remove an address from the whitelist
     * @param _address The address to disallow
     */
    function disallow(address _address) public onlyOwner {
        allowedAddresses[_address] = false;
        emit AccessRevoked(_address);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
