// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import "./ChainlinkAdapter.sol";

contract ChainlinkWrappedAdapter is ChainlinkAdapter {
    using SafeInt256 for int256;

    AggregatorV2V3Interface public immutable baseToWrappedOracle;
    int256 public immutable baseToWrappedDecimals;

    constructor (
        AggregatorV2V3Interface baseToUSDOracle_,
        AggregatorV2V3Interface baseToWrappedOracle_,
        AggregatorV2V3Interface quoteToUSDOracle_,
        string memory description_
    ) ChainlinkAdapter(baseToUSDOracle_, quoteToUSDOracle_, description_) {
        baseToWrappedOracle = baseToWrappedOracle_;
        baseToWrappedDecimals = int256(10**baseToWrappedOracle_.decimals());
    }

    function _calculateBaseToQuote() internal view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        int256 baseToUSD;
        (
            roundId,
            baseToUSD,
            startedAt,
            updatedAt,
            answeredInRound
        ) = baseToUSDOracle.latestRoundData();
        require(baseToUSD > 0, "Chainlink Rate Error");

        // Convert the base value to the wrapped value
        (
            /* roundId */,
            int256 baseToWrapped,
            /* uint256 startedAt */,
            /* updatedAt */,
            /* answeredInRound */
        ) = baseToWrappedOracle.latestRoundData();
        // Converting base to wrapped (keeping baseUSD decimals):
        // (base/USD * baseToWrappedRate) / (wrappedDecimals)
        baseToUSD = baseToUSD.mul(baseToWrapped).div(baseToWrappedDecimals);

        (
            /* roundId */,
            int256 quoteToUSD,
            /* uint256 startedAt */,
            /* updatedAt */,
            /* answeredInRound */
        ) = quoteToUSDOracle.latestRoundData();
        require(quoteToUSD > 0, "Chainlink Rate Error");

        // To convert from USDC/USD (base) and ETH/USD (quote) to USDC/ETH we do:
        // (USDC/USD * quoteDecimals * 1e18) / (ETH/USD * baseDecimals)
        answer = baseToUSD
            .mul(quoteToUSDDecimals)
            .mul(rateDecimals)
            .div(quoteToUSD)
            .div(baseToUSDDecimals);
    }

}
