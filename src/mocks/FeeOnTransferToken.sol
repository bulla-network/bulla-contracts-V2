// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";

contract FeeOnTransferToken is ERC20 {
    address feeReceiver = address(0xBEEF);
    uint256 public FEE_BPS = 100; // 1% fee

    constructor() ERC20("FeeToken", "LAME", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10000;
        super.transferFrom(from, to, amount - fee);
        super.transferFrom(from, feeReceiver, fee);

        return true;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
