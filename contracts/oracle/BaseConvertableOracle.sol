// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "interfaces/notional/ICombinedOracle.sol";
import "interfaces/chainlink/AggregatorV3Interface.sol";
import "../common/ExchangeRate.sol";

abstract contract BaseCombinedOracle is ICombinedOracle {
    struct SettledRate {
        uint128 settledRate;
        bool hasSettled;
    }

    uint8 public decimals;
    uint256 public constant version = 1;

    ExchangeRate.Rate public underlyingOracle;
    ExchangeRate.Rate public assetOracle;
    // Mapping from a maturity to its settled rate
    mapping(uint => SettledRate) public settledRate;

    constructor(
        address underlying,
        bool underlyingMustInvert,
        address asset,
        uint8 baseDecimalPlaces,
        uint8 assetRateDecimalPlaces,
        bool assetMustInvert
    ) {
        uint8 underlyingDecimalPlaces = AggregatorV3Interface(underlying).decimals();

        underlyingOracle = ExchangeRate.Rate({
            rateOracle: underlying,
            rateDecimalPlaces: underlyingDecimalPlaces,
            mustInvert: underlyingMustInvert,
            buffer: ExchangeRate.BUFFER_DECIMALS
        });

        assetOracle = ExchangeRate.Rate({
            rateOracle: asset,
            rateDecimals: assetRateDecimalPlaces,
            mustInvert: assetMustInvert,
            buffer: ExchangeRate.BUFFER_DECIMALS
        });

        // This sets the decimal places for the combined oracle
        if (underlyingDecimalPlaces < assetRateDecimalPlaces) {
            decimals = underlyingDecimalPlaces;
        } else {
            decimals = assetRateDecimalPlaces;
        }
    }

    /**
     * @notice It is not possible for us to retrieve historical prices for combined oracles,
     * with the exception of settled rates (but this is not the same as an exchange rate to ETH)
     */
    function getRoundData(uint80 _roundId) external override view returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
        revert($$(ErrorCode(UNIMPLEMENTED)));
    }

    /**
     * @notice Returns the combined rate from the asset to the oracle quote rate.
     * @return underlying round data with the updated combined rate
     */
    function latestRoundData() external override returns (uint80, int256, uint256, uint256, uint80) {
        ExchangeRate.Rate memory underlying = underlyingOracle;

        (
            uint80 roundId, 
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = AggregatorV3Interface(underlying.rateOracle).latestRoundData();
        require(rate > 0, $$(ErrorCode(INVALID_EXCHANGE_RATE)));

        uint256 rate = uint256(answer);
        if (underlying.mustInvert) {
            rate = uint256(underlying.rateDecimals)
                .mul(underlying.rateDecimals)
                .div(rate);
        }

        // Returns the exchange rate of the asset back to the underlying
        uint128 assetRate = getAssetRate();

        // assetRate * rate * baseDecimals / (assetRateDecimals * rateDecimals)
        int256 result = int256(
            SafeCast.toUint128(rate
                .mul(baseDecimals)
                .mul(assetRate)
                .div(assetRateDecimals)
                .div(underlying.rateDecimals)
            )
        );

        return (
            roundId,
            result,
            startedAt,
            updatedAt,
            answeredInRound
        );
    }

    function getSettledRate(uint maturity) external view returns (int256) {
        SettledRate settled = settledRate[maturity];
        require(settled.hasSettled, "oracle: rate not settled");

        return int256(settled.settledRate);
    }

    function getOrSetSettledRate(uint maturity) external returns (int256) {
        SettledRate settled = settledRate[maturity];
        if (!settled.hasSettled) {
            uint128 rate = getAssetRate();
            settledRate[maturity] = SettledRate({
                settledRate: rate,
                hasSettled: true
            });

            return int256(rate);
        }

        return int256(settled.settledRate);
    }

    function getAssetRate() external virtual returns (uint rate);
    function description() external virtual returns (string memory);
}