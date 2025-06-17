// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "solmate/auth/Owned.sol";

contract BullaControllerRegistry is Owned {
    mapping(address => string) private _controllers;

    string public constant DEFAULT_CONTROLLER_NAME = "WARNING: CONTRACT UNKNOWN";

    constructor() Owned(msg.sender) {}

    function getControllerName(address _controllerAddress) external view returns (string memory) {
        string memory controller = _controllers[_controllerAddress];
        if (bytes(controller).length == 0) controller = DEFAULT_CONTROLLER_NAME;
        return controller;
    }

    function setControllerName(address controller, string calldata name) external onlyOwner {
        _controllers[controller] = name;
    }
}
