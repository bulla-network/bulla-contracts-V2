// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20MockLegacy is ERC20 {
    constructor(string memory name, string memory symbol, address initialAccount, uint256 initialBalance)
        ERC20(name, symbol)
    {
        if (initialAccount != address(0) && initialBalance > 0) {
            _mint(initialAccount, initialBalance);
        }
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
