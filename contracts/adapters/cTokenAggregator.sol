// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "./StatefulAggregatorV3Interface.sol";
import "interfaces/compound/CTokenInterface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract cTokenAggregator is StatefulAggregatorV3Interface {
    address public cToken;
    uint8 public override decimals = 18;
    uint256 public override version = 1;
    string public override description;

    constructor(address _cToken) {
        cToken = _cToken;
        description = ERC20(_cToken).symbol();
    }

    /** @notice It is not possible for us to retrieve historical exchange rates for cTokens */
    function getRoundData(uint80 /* _roundId */) external override pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("Unimplmented");
    }

    /** @notice Returns the current exchange rate for the cToken to the underlying */
    function latestRoundData() external override returns (uint80, int256, uint256, uint256, uint80) {
        uint exchangeRate = CTokenInterface(cToken).exchangeRateCurrent();
        require(exchangeRate <= uint(type(int256).max), "cTokenOracle: overflow");

        return (0, int(exchangeRate), 0, 0, 0);
    }
}