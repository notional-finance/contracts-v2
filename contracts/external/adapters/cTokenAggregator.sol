// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;

import "interfaces/notional/AssetRateAdapter.sol";
import "interfaces/compound/CTokenInterface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract cTokenAggregator is AssetRateAdapter {
    using SafeMath for uint256;

    CTokenInterface private immutable cToken;
    uint8 public override decimals = 18;
    uint256 public override version = 1;
    string public override description;
    // This is defined in the Compound interest rate model:
    // https://github.com/compound-finance/compound-protocol/blob/b9b14038612d846b83f8a009a82c38974ff2dcfe/contracts/JumpRateModel.sol#L18
    uint256 public constant BLOCKS_PER_YEAR = 2102400;
    // Notional rate precision = 1e9
    // Compound rate precision = 1e18
    uint256 public constant SCALE_RATE = 1e9;

    constructor(CTokenInterface _cToken) {
        cToken = _cToken;
        description = ERC20(address(_cToken)).symbol();
    }

    function token() external view override returns (address) {
        return address(cToken);
    }

    function underlying() external view override returns (address) {
        return cToken.underlying();
    }

    function _checkExchangeRate(uint256 exchangeRate) private pure {
        require(exchangeRate <= uint256(type(int256).max), "cTokenAdapter: overflow");
    }

    /** @notice Returns the current exchange rate for the cToken to the underlying */
    function getExchangeRateStateful() external override returns (int256) {
        uint256 exchangeRate = cToken.exchangeRateCurrent();
        _checkExchangeRate(exchangeRate);

        return int256(exchangeRate);
    }

    function getExchangeRateView() external view override returns (int256) {
        uint256 exchangeRate = cToken.exchangeRateStored();
        _checkExchangeRate(exchangeRate);

        return int256(exchangeRate);
    }

    function getAnnualizedSupplyRate() external view override returns (uint256) {
        uint256 supplyRatePerBlock = cToken.supplyRatePerBlock();

        // Although the Compound documentation recommends doing a per day compounding of the supply
        // rate to get the annualized rate (https://compound.finance/docs#protocol-math), we just do a
        // simple linear approximation of the rate here. Since Compound rates are variable per block
        // any rate we calculate here will be an approximation and so this is the simplest implementation
        // that gets a pretty good answer. Supply rates are only used when valuing idiosyncratic fCash assets
        // that are shorter dated than the 3 month fCash market.

        // Supply rate per block * blocks per year * notional rate precision / supply rate precision
        return supplyRatePerBlock.mul(BLOCKS_PER_YEAR).div(SCALE_RATE);
    }
}
