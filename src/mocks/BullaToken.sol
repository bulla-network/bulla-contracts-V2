//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract BullaToken is ERC20 {
    constructor() ERC20("Bulla Token", "BULLA") {
        _mint(msg.sender, 1000000 ether);
    }
}
