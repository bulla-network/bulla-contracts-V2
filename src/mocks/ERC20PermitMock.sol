// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract ERC20PermitMock is ERC20, ERC20Permit {
    constructor(string memory name, string memory symbol, address initialAccount, uint256 initialBalance)
        ERC20(name, symbol)
        ERC20Permit(name)
    {
        _mint(initialAccount, initialBalance);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
