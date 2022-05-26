// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import "../../interfaces/aave/IAToken.sol";

contract MockAToken is IAToken {
    address public override immutable UNDERLYING_ASSET_ADDRESS;
    string public override symbol;

    constructor(address _underlying, string memory _symbol) {
        UNDERLYING_ASSET_ADDRESS = _underlying;
        symbol = _symbol;
    }

    function scaledBalanceOf(address user) external view override returns (uint256) {
        return 0;
    }
}