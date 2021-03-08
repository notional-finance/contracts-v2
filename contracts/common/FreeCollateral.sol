// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetHandler.sol";
import "./CashGroup.sol";
import "./ExchangeRate.sol";
import "../math/SafeInt256.sol";
import "../storage/BalanceHandler.sol";
import "../storage/PortfolioHandler.sol";

library FreeCollateral {
    using SafeInt256 for int;
    using Bitmap for bytes;
    using PortfolioHandler for PortfolioState;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;

    function setupFreeCollateral(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal view returns (
        PortfolioAsset[] memory,
        int[] memory,
        CashGroupParameters[] memory,
        MarketParameters[][] memory
    ) {
        PortfolioAsset[] memory allActiveAssets = portfolioState.getMergedArray();
        (
            CashGroupParameters[] memory cashGroups, 
            MarketParameters[][] memory marketStates
        ) = getAllCashGroups(portfolioState.storedAssets);

        // This changes references in memory, must ensure that we optmisitically write
        // changes to storage using _finalizeState in BaseAction before we execute this method
        int[] memory netPortfolioValue = AssetHandler.getPortfolioValue(
            allActiveAssets,
            cashGroups,
            marketStates,
            blockTime,
            true // Must be risk adjusted
        );

        return (allActiveAssets, netPortfolioValue, cashGroups, marketStates);
    }

    /**
     * @notice Aggregates the portfolio value with cash balances to get the net free collateral value.
     */
    function getFreeCollateral(
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue
    ) internal view returns (int) {
        uint groupIndex;
        int netETHValue;

        for (uint i; i < balanceState.length; i++) {
            // Cash balances are denominated in underlying
            int perpetualTokenValue;
            int netLocalAssetValue = balanceState[i].storedCashBalance;
            if (balanceState[i].storedPerpetualTokenBalance > 0) {
                // TODO: change this
                perpetualTokenValue = balanceState[i].getPerpetualTokenAssetValue();
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            AssetRateParameters memory assetRate;
            if (cashGroups[groupIndex].currencyId == balanceState[i].currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                groupIndex += 1;
            } else {
                // TODO: there is a stateful and non-stateful version of this function
                assetRate = AssetRate.buildAssetRate(balanceState[i].currencyId);
            }
            // TODO: short circuit this if the currency is ETH
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(balanceState[i].currencyId);
            int ethValue = ethRate.convertToETH(
                assetRate.convertInternalToUnderlying(netLocalAssetValue)
            );

            netETHValue = netETHValue.add(ethValue);
        }

        return netETHValue;
    }

    /**
     * @notice Ensures that all cash groups in a set of active assets are in the list of cash groups.
     * Cash groups can be in the active assets but not loaded yet if they have been previously traded.
     */
    function getAllCashGroups(
        PortfolioAsset[] memory assets
    ) internal view returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        uint groupIndex;
        uint lastCurrencyId;

        // Count the number of groups
        for (uint i; i < assets.length; i++) {
            if (lastCurrencyId != assets[i].currencyId) {
                groupIndex += 1;
                lastCurrencyId = assets[i].currencyId;
            }
        }

        CashGroupParameters[] memory cashGroups = new CashGroupParameters[](groupIndex);
        MarketParameters[][] memory marketStates = new MarketParameters[][](groupIndex);
        groupIndex = 0;
        lastCurrencyId = 0;
        for (uint i; i < assets.length; i++) {
            if (lastCurrencyId != assets[i].currencyId) {
                (
                    cashGroups[groupIndex],
                    marketStates[groupIndex]
                ) = CashGroup.buildCashGroup(assets[i].currencyId);
                groupIndex += 1;
                lastCurrencyId = assets[i].currencyId;
            }
        }

        return (cashGroups, marketStates);
    }
}
