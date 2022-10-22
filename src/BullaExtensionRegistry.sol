// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "solmate/auth/Owned.sol";

contract BullaExtensionRegistry is Owned {
    mapping(address => string) public extensions;

    error NotFound();

    constructor() Owned(msg.sender) {}

    function getExtension(address _address) external view returns (string memory) {
        string memory extension = extensions[_address];
        if (bytes(extension).length == 0) revert NotFound();
        return extension;
    }

    function getExtensionForSignature(address _operatorAddress) external view returns (string memory) {
        string memory extension = extensions[_operatorAddress];
        if (bytes(extension).length == 0) extension = "WARNING: CONTRACT UNKNOWN";
        return extension;
    }

    function setExtensionName(address extension, string calldata name) external onlyOwner {
        extensions[extension] = name;
    }
}
