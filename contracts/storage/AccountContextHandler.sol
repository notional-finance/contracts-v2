// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "../common/CashGroup.sol";
import "../math/SafeInt256.sol";
import "../math/Bitmap.sol";
import "./PortfolioHandler.sol";


enum TradeAction {
    AddLiquidity,
    RemoveLiquidity,
    TakefCash,
    TakeCurrentCash,
    MintCashPair
}

struct TradeRequest {
    TradeAction tradeAction;
    uint maturity;
    uint notional;
    // Context dependent trade request data
    bytes data;
}

struct BatchedTradeRequest {
    uint currencyId;
    TradeRequest[] tradeRequests;
}

/**
 * @dev Reads storage parameters and creates context structs for different actions.
 */
library AccountContextHandler {
    /**
    uint internal constant ACCOUNT_CONTEXT_STORAGE_SLOT;

     * @notice Gets context for trading. Requires that cash groups are sorted ascending and
     * trade requests are sorted ascending by maturity.
    function getTradeContext(
        uint blockTime,
        BatchedTradeRequest[] calldata requestBatch
    ) internal view returns (
        CashGroupParameters[] memory,
        MarketParameters[][] memory
    ) {
        CashGroupParameters[] memory cashGroups = new CashGroupParameters[](requestBatch.length);
        MarketParameters[][] memory marketParameters = new MarketParameters[][](requestBatch.length);
        Rate memory assetRate;
        // Storage Read
        uint _maxCurrencyId = maxCurrencyId;

        for (uint i; i < requestBatch.length; i++) {
            uint currencyId = requestBatch[i].currencyId;
            require(currencyId <= _maxCurrencyId && currencyId != 0, "R: invalid currency id");
            if (i > 0) {
                require(
                    requestBatch[i - 1].currencyId < currencyId,
                    "R: cash groups unsorted"
                );
            }

            assetRate = ExchangeRate.buildExchangeRate(
                // Storage Read
                assetToUnderlyingRateMapping[currencyId]
            );

            cashGroups[i] = CashGroup.buildCashGroup(
                currencyId,
                cashGroupMapping[currencyId],
                assetRate
            );

            marketParameters[i] = getMarketParameters(
                blockTime,
                requestBatch[i].tradeRequests,
                cashGroups[i]
            );
        }

        return (cashGroups, marketParameters);
    }
     */

    /**
     * @notice Returns market parameters for every market that is being traded.
    function getMarketParameters(
        uint blockTime,
        TradeRequest[] calldata tradeRequests,
        CashGroupParameters memory cashGroup
    ) internal view returns (MarketParameters[] memory) {
        uint marketStateCount;

        for (uint i; i < tradeRequests.length; i++) {
            uint maturity = tradeRequests[i].maturity;
            if (i > 0) {
                require(
                    tradeRequests[i - 1].maturity <= maturity,
                    "R: trade requests unsorted"
                );
            }

            if (tradeRequests[i].tradeAction == TradeAction.MintCashPair) {
                // Check that the ifCash asset is valid as early as possible
                require(
                    cashGroup.isValidIdiosyncraticMaturity(maturity, blockTime) != 0,
                    "R: invalid maturity"
                );

                // No market state required for minting a cash pair
                continue;
            }

            require(
                cashGroup.isValidMaturity(maturity, blockTime),
                "R: invalid maturity"
            );

            // Don't update count for matching maturities, this can happen if someone is adding liquidity
            // and then borrowing in a single maturity.
            if (i > 0 && tradeRequests[i - 1].maturity == maturity) continue;
            marketStateCount += 1;
        }

        MarketParameters[] memory mp = new MarketParameters[](marketStateCount);
        if (marketStateCount == 0) return mp;

        marketStateCount = 0;
        for (uint i; i < tradeRequests.length; i++) {
            if (tradeRequests[i].tradeAction == TradeAction.MintCashPair) continue;
            uint maturity = tradeRequests[i].maturity;

            if (i > 0 && marketStateCount > 0 && tradeRequests[i - 1].maturity == maturity) {
                // If the previous maturity matches this one, check if total liquidity is required
                // and if so then set it (if not set already)
                if ((tradeRequests[i].tradeAction == TradeAction.AddLiquidity ||
                     tradeRequests[i].tradeAction == TradeAction.RemoveLiquidity)
                    && mp[marketStateCount - 1].totalLiquidity == 0) {
                    
                    // Storage Read
                    mp[marketStateCount - 1].totalLiquidity = marketTotalLiquidityMapping[cashGroup.currencyId][maturity];
                }

                continue;
            }

            int totalLiquidity;
            if (tradeRequests[i].tradeAction == TradeAction.AddLiquidity ||
                tradeRequests[i].tradeAction == TradeAction.RemoveLiquidity) {
                // Storage Read
                totalLiquidity = marketTotalLiquidityMapping[cashGroup.currencyId][maturity];
            }

            mp[marketStateCount] = Market.buildMarket(
                cashGroup.currencyId,
                maturity,
                totalLiquidity,
                cashGroup.getRateOracleTimeWindow(),
                blockTime,
                // Storage Read
                marketStateMapping[cashGroup.currencyId][maturity]
            );
            marketStateCount += 1;
        }

        return mp;
    }
     */

}