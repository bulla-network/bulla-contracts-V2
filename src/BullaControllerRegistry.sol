// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "solmate/auth/Owned.sol";

contract BullaControllerRegistry is Owned {
    mapping(address => string) public controllers;

    error NotFound();

    constructor() Owned(msg.sender) {}

    function getController(address _address) external view returns (string memory) {
        string memory controller = controllers[_address];
        if (bytes(controller).length == 0) revert NotFound();
        return controller;
    }

    function getControllerName(address _controllerAddress) external view returns (string memory) {
        string memory controller = controllers[_controllerAddress];
        if (bytes(controller).length == 0) controller = "WARNING: CONTRACT UNKNOWN";
        return controller;
    }

    function setControllerName(address controller, string calldata name) external onlyOwner {
        controllers[controller] = name;
    }
}
