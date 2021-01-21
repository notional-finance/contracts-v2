// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _setupDecimals(decimals_);
        _mint(msg.sender, 10**decimals_ * 1e10);
    }
}