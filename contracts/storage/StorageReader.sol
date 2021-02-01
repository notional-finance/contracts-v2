// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "../common/CashGroup.sol";
import "../math/SafeInt256.sol";
import "../math/Bitmap.sol";
import "./PortfolioHandler.sol";

// This should be a bitmap to handle both update more elegantly
enum BalanceStorageState {
    NoChange,
    CashBalanceUpdate,
    PerpetualTokenUpdate,
    BothUpdate
}

struct BalanceContext {
    uint currencyId;
    int cashBalance;
    uint perpetualTokenBalance;
    BalanceStorageState storageState;
}

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

struct NetAssetChange {
    uint maturity;
    uint assetType;
    int notional;
}

struct BatchedTradeRequest {
    uint currencyId;
    TradeRequest[] tradeRequests;
}

/**
 * @dev Reads storage parameters and creates context structs for different actions.
 */
contract StorageReader is StorageLayoutV1 {
    using SafeInt256 for int256;
    using Bitmap for bytes;
    using CashGroup for CashGroupParameters;

    /**
     * @notice Reads the account context from state and settles assets if required.
     */
    function getInitializeContext(
        address account,
        uint blockTime,
        uint newAssetsHint
    ) internal view returns (AccountStorage memory, PortfolioState memory) {
        // Storage Read
        AccountStorage memory accountContext = accountContextMapping[account];
        PortfolioState memory portfolioState;

        if (accountContext.nextMaturingAsset <= blockTime || newAssetsHint > 0) {
            // We only fetch the portfolio state if there will be new assets added or if the account
            // must be settled.
            portfolioState = PortfolioHandler.buildPortfolioState(
                assetArrayMapping[account], newAssetsHint
            );
        }

        return (accountContext, portfolioState);
    }

    /**
     * @notice Gets a cash balance context object which tracks changes to a currency's balance.
     */
    function getBalanceContext(
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) internal view returns (BalanceContext memory) {
        BalanceContext memory context;
        // Storage Read
        uint _maxCurrencyId = maxCurrencyId;
        require(currencyId <= _maxCurrencyId && currencyId != 0, "R: invalid currency id");
        bool isActive = accountContext.activeCurrencies.isBitSet(currencyId);

        if (isActive) {
            // Set the bit to off to mark that we've read the balance
            accountContext.activeCurrencies = Bitmap.setBit(
                accountContext.activeCurrencies,
                currencyId,
                false
            );
            // Storage Read
            BalanceStorage memory balance = accountBalanceMapping[account][currencyId];
            return BalanceContext({
                currencyId: currencyId,
                cashBalance: balance.cashBalance,
                perpetualTokenBalance: balance.perpetualTokenBalance,
                storageState: BalanceStorageState.NoChange
            });
        }

        return BalanceContext({
            currencyId: currencyId,
            cashBalance: 0,
            perpetualTokenBalance: 0,
            storageState: BalanceStorageState.NoChange
        });
    }

    /**
     * @notice When doing a free collateral check we must get all active balances, this will
     * fetch any remaining balances and exchange rates that are active on the account.
     */
    function getRemainingActiveBalances(
        address account,
        bytes memory activeCurrencies
    ) internal view returns (BalanceContext[] memory) {
        uint totalActive = activeCurrencies.totalBitsSet();
        BalanceContext[] memory newBalanceContext = new BalanceContext[](totalActive);
        totalActive = 0;

        for (uint i; i < activeCurrencies.length; i++) {
            // Scan for the remaining balances in the active currencies list
            if (activeCurrencies[i] == 0x00) continue;

            bytes1 bits = activeCurrencies[i];
            for (uint offset; offset < 8; offset++) {
                if (bits == 0x00) break;

                // The big endian bit is set to one so we get the balance context for this currency id
                if (bits & 0x80 == 0x80) {
                    uint currencyId = (i * 8) + offset + 1;
                    BalanceStorage memory balance = accountBalanceMapping[account][currencyId];
                    newBalanceContext[totalActive] = BalanceContext({
                        currencyId: currencyId,
                        cashBalance: balance.cashBalance,
                        perpetualTokenBalance: balance.perpetualTokenBalance,
                        storageState: BalanceStorageState.NoChange
                    });
                    totalActive += 1;
                }

                bits = bits << 1;
            }
        }

        return newBalanceContext;
    }

    /**
     * @notice Gets context for trading. Requires that cash groups are sorted ascending and
     * trade requests are sorted ascending by maturity.
     */
    function getTradeContext(
        uint blockTime,
        BatchedTradeRequest[] calldata requestBatch
    )  internal view returns (
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

    /**
     * @notice Returns market parameters for every market that is being traded.
     */
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
                cashGroup.rateOracleTimeWindow,
                blockTime,
                // Storage Read
                marketStateMapping[cashGroup.currencyId][maturity]
            );
            marketStateCount += 1;
        }

        return mp;
    }

}

contract MockStorageReader is StorageReader {
    using Bitmap for bytes;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function setCurrencyMapping(
        uint id,
        CurrencyStorage calldata cs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        currencyMapping[id] = cs;
    }

    function setETHRateMapping(
        uint id,
        RateStorage calldata rs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        underlyingToETHRateMapping[id] = rs;
    }

    function setAssetRateMapping(
        uint id,
        RateStorage calldata rs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setCashGroup(
        uint id,
        CashGroupParameterStorage calldata cg
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        cashGroupMapping[id] = cg;
    }

    function setMarketState(
        uint id,
        uint maturity,
        MarketStorage calldata ms,
        uint80 totalLiquidity
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        marketStateMapping[id][maturity] = ms;
        marketTotalLiquidityMapping[id][maturity] = totalLiquidity;
    }

    function setAccountContext(
        address account,
        AccountStorage memory a
    ) external {
        accountContextMapping[account] = a;
    }

    function setAssetArray(
        address account,
        AssetStorage[] memory a
    ) external {
        // Clear array
        delete assetArrayMapping[account];

        AssetStorage[] storage s = assetArrayMapping[account];
        for (uint i; i < a.length; i++) {
            s.push(a[i]);
        }
    }

    function setAssetBitmap(
        address account,
        uint id,
        bytes memory bitmap
    ) external {
        assetBitmapMapping[account][id] = bitmap;
    }

    function setifCash(
        address account,
        uint id,
        uint maturity,
        int notional
    ) external {
        ifCashMapping[account][id][maturity] = notional;
    }

    function setBalance(
        address account,
        uint id,
        BalanceStorage calldata bs
    ) external {
        accountBalanceMapping[account][id] = bs;
    }

    function _getInitializeContext(
        address account,
        uint blockTime,
        uint newAssetsHint
    ) public view returns (AccountStorage memory, PortfolioState memory) {
        return getInitializeContext(account, blockTime, newAssetsHint);
    }

    function _getBalanceContext(
        address account,
        uint currencyId
    ) public view returns (
        BalanceContext memory,
        AccountStorage memory
    ) {
        AccountStorage memory accountContext = accountContextMapping[account];

        BalanceContext memory balanceContext = getBalanceContext(
            account,
            currencyId,
            accountContext
        );

        BalanceStorage memory s = accountBalanceMapping[account][currencyId];
        assert(balanceContext.cashBalance == s.cashBalance);
        assert(balanceContext.perpetualTokenBalance == s.perpetualTokenBalance);
        assert(accountContext.activeCurrencies.isBitSet(currencyId) == false);

        return (balanceContext, accountContext);
    }

    function _getRemainingActiveBalances(
        address account,
        bytes memory activeCurrencies
    ) public view returns (BalanceContext[] memory) {
        BalanceContext[] memory bc = getRemainingActiveBalances(
            account,
            activeCurrencies
        );

        assert(bc.length == activeCurrencies.totalBitsSet());
        for(uint i; i < bc.length; i++) {
            assert(bc[i].currencyId != 0);
        }

        return bc;
    }

    function _getTradeContext(
        uint blockTime,
        BatchedTradeRequest[] calldata requestBatch
    ) public view returns (
        CashGroupParameters[] memory,
        MarketParameters[][] memory
    ) {
        return getTradeContext(
            blockTime,
            requestBatch
        );
    }

    function _getMarketParameters(
        uint blockTime,
        TradeRequest[] calldata tradeRequests,
        CashGroupParameters memory cashGroup
    ) public view returns (MarketParameters[] memory) {
        return getMarketParameters(
            blockTime,
            tradeRequests,
            cashGroup
        );
    }

}