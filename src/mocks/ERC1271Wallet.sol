// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "contracts/interfaces/IERC1271.sol";

contract ERC1271WalletMock is IERC1271 {
    mapping(bytes32 => bool) public signatures;

    function sign(bytes32 digest) external {
        signatures[digest] = true;
    }

    function isValidSignature(bytes32 hash, bytes memory) public view override returns (bytes4 magicValue) {
        return signatures[hash] ? this.isValidSignature.selector : bytes4(0);
    }
}
