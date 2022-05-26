// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../../interfaces/notional/AssetRateAdapter.sol";
import "../../../interfaces/aave/ILendingPool.sol";
import "../../../interfaces/aave/IAToken.sol";
import "../../global/Constants.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract aTokenAggregator is AssetRateAdapter {
    using SafeMath for uint256;

    ILendingPool public immutable LendingPool;
    uint256 public immutable INDEX_SCALE_FACTOR;

    address public override immutable underlying;
    address public override immutable token;
    uint8 public override immutable decimals;
    uint256 public override version = 1;
    string public override description;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant NOTIONAL_ASSET_RATE_DECIMAL_DIFFERENCE = 1e10;
    uint256 internal constant halfRAY = RAY / 2;

    constructor(ILendingPool _lendingPool, IAToken _aToken) {
        ERC20 underlyingERC20 = ERC20(_aToken.UNDERLYING_ASSET_ADDRESS());
        uint8 underlyingDecimals = underlyingERC20.decimals();
        // Prevent overflow when doing powers of 10
        require(underlyingDecimals <= Constants.MAX_DECIMAL_PLACES);

        // Set all the immutable constants
        INDEX_SCALE_FACTOR = (10**underlyingDecimals) * NOTIONAL_ASSET_RATE_DECIMAL_DIFFERENCE;
        // Rate is specified in this precision due to backwards compatibility with cToken asset rates
        decimals = underlyingDecimals + 10;
        LendingPool = _lendingPool;
        token = address(_aToken);
        underlying = address(underlyingERC20);
        description = _aToken.symbol();
    }

    /** 
     * @notice Returns the current exchange rate for the aToken to the underlying
     * @dev Unlike compound this function call in Aave is not stateful. However we keep the
     * modifiers here to maintain compatibility with the cTokenAggregator.
     */
    function getExchangeRateStateful() external override returns (int256) {
        return _getNotionalExchangeRate();
    }

    /** @notice Returns the current exchange rate for the aToken to the underlying */
    function getExchangeRateView() external view override returns (int256) {
        return _getNotionalExchangeRate();
    }

    function getAnnualizedSupplyRate() external view override returns (uint256) {
        ILendingPool.ReserveData memory data = LendingPool.getReserveData(underlying);
        // This is already the annualized supply rate in RAY. Notional expects this annualized rate in
        // 1e9 precision so we scale it properly here. Also Aave uses 365 day years but Notional uses 360
        // day years. We do not make an adjustment here since the effect is small (1%) and the Aave rate
        // is variable regardless. We only use this supply rate for idiosyncratic fCash valuation at less
        // than 3m.
        //      currentLiquidityRate * 1e9 / 1e27
        //      currentLiquidityRate / 1e18
        return uint256(data.currentLiquidityRate).div(1e18);
    }

    function _getNotionalExchangeRate() private view returns (int256) {
        uint256 index = LendingPool.getReserveNormalizedIncome(underlying);

        // Aave formula to convert scaledBalanceOf to balanceOf (asset cash to underlying cash) is:
        // balanceOf = rayMul(scaledBalanceOf, index)
        //      index is in 1e27 precision (RAY)
        //      balanceOf and scaledBalanceOf are in underlying decimal precision
        //      multiplication and division round up on half

        // Internally in Notional we use a calculation compatible with cToken exchange rates which
        // normalize from 8 decimal places to the underlying decimal places:
        // internalBalance * rate * internalPrecision / rateDecimals * underlyingPrecision
        //      internalBalance is in 1e8 precision (internalPrecision). 
        //      rate is in 1e(18 + underlyingDecimals) precision (rateDecimals)
        //      underlyingPrecision is the decimals of the underlying
        //
        // Aave exchange rates are all in 1e27 precision. In this case we convert it to the required
        // Notional precision which is:
        //     1e(18 + underlyingDecimals - 8) == INDEX_SCALE_FACTOR

        uint256 rate = index.mul(INDEX_SCALE_FACTOR).div(RAY);
        require(rate <= uint256(type(int256).max));
        return int256(rate);
    }
}