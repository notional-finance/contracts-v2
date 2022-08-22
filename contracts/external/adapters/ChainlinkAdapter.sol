// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import "../../math/SafeInt256.sol";
import "../../../interfaces/chainlink/AggregatorV2V3Interface.sol";

contract ChainlinkAdapter is AggregatorV2V3Interface {
    using SafeInt256 for int256;
    uint8 public override constant decimals = 18;
    uint256 public override constant version = 1;
    int256 public constant rateDecimals = 10**18;

    string public override description;
    AggregatorV2V3Interface public immutable baseToUSDOracle;
    int256 public immutable baseToUSDDecimals;
    AggregatorV2V3Interface public immutable quoteToUSDOracle;
    int256 public immutable quoteToUSDDecimals;

    constructor (
        AggregatorV2V3Interface baseToUSDOracle_,
        AggregatorV2V3Interface quoteToUSDOracle_,
        string memory description_
    ) {
        description = description_;
        baseToUSDOracle = baseToUSDOracle_;
        quoteToUSDOracle = quoteToUSDOracle_;
        baseToUSDDecimals = int256(10**baseToUSDOracle_.decimals());
        quoteToUSDDecimals = int256(10**quoteToUSDOracle_.decimals());
    }

    function _calculateBaseToQuote() internal view returns (
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

    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return _calculateBaseToQuote();
    }

    function latestAnswer() external view override returns (int256 answer) {
        (/* */, answer, /* */, /* */, /* */) = _calculateBaseToQuote();
    }

    function latestTimestamp() external view override returns (uint256 updatedAt) {
        (/* */, /* */, /* */, updatedAt, /* */) = _calculateBaseToQuote();
    }

    function latestRound() external view override returns (uint256 roundId) {
        (roundId, /* */, /* */, /* */, /* */) = _calculateBaseToQuote();
    }

    function getRoundData(uint80 /* _roundId */) external view override returns (
        uint80 /* roundId */,
        int256 /* answer */,
        uint256 /* startedAt */,
        uint256 /* updatedAt */,
        uint80 /* answeredInRound */
    ) {
        revert();
    }

    function getAnswer(uint256 /* roundId */) external view override returns (int256) { revert(); }
    function getTimestamp(uint256 /* roundId */) external view override returns (uint256) { revert(); }
}
