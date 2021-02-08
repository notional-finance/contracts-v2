// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "./AssetRateAdapterInterface.sol";
import "interfaces/compound/CTokenInterface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract cTokenAggregator is AssetRateAdapterInterface {
    using SafeMath for uint256;

    address public cToken;
    uint8 public override decimals = 18;
    uint256 public override version = 1;
    string public override description;
    uint public constant BLOCKS_PER_YEAR = 2102400;
    // Notional rate precision = 1e9
    // Compound rate precision = 1e18
    uint public constant SCALE_RATE = 1e9;

    constructor(address _cToken) {
        cToken = _cToken;
        description = ERC20(_cToken).symbol();
    }

    /** @notice Returns the current exchange rate for the cToken to the underlying */
    function getExchangeRateStateful() external override returns (int) {
        uint exchangeRate = CTokenInterface(cToken).exchangeRateCurrent();
        require(exchangeRate <= uint(type(int256).max), "cTokenAdapter: overflow");

        return int(exchangeRate);
    }

    function getExchangeRateView() external view override returns (int) {
        uint exchangeRate = CTokenInterface(cToken).exchangeRateStored();
        require(exchangeRate <= uint(type(int256).max), "cTokenAdapter: overflow");

        return int(exchangeRate);
    }

    function getAnnualizedSupplyRate() external view override returns (uint) {
        uint supplyRatePerBlock = CTokenInterface(cToken).supplyRatePerBlock();

        // Supply rate per block * blocks per year * notional rate precision / supply rate precision
        return supplyRatePerBlock.mul(BLOCKS_PER_YEAR).div(SCALE_RATE);
    }
}