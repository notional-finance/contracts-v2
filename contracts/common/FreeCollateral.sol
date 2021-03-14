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
    using PerpetualToken for PerpetualTokenPortfolio;

    function setupFreeCollateralStateful(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal returns (
        PortfolioAsset[] memory,
        int[] memory,
        CashGroupParameters[] memory,
        MarketParameters[][] memory
    ) {
        PortfolioAsset[] memory allActiveAssets = portfolioState.getMergedArray();
        (
            CashGroupParameters[] memory cashGroups, 
            MarketParameters[][] memory marketStates
        ) = getAllCashGroupsStateful(portfolioState.storedAssets);

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

    function setupFreeCollateralView(
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
        ) = getAllCashGroupsView(portfolioState.storedAssets);

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
    function getFreeCollateralStateful(
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue,
        uint blockTime
    ) internal returns (int) {
        uint groupIndex;
        int netETHValue;

        for (uint i; i < balanceState.length; i++) {
            // TODO: we can just fetch the balance storage here
            int netLocalAssetValue = balanceState[i].storedCashBalance;
            if (balanceState[i].storedPerpetualTokenBalance > 0) {
                PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(
                    balanceState[i].currencyId
                );
                // TODO: this will return an asset rate as well, so we can use it here
                int perpetualTokenValue = getPerpetualTokenAssetValue(
                    perpToken,
                    balanceState[i].storedPerpetualTokenBalance,
                    blockTime
                );
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            AssetRateParameters memory assetRate;
            if (cashGroups[groupIndex].currencyId == balanceState[i].currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                groupIndex += 1;
            } else {
                assetRate = AssetRate.buildAssetRateStateful(balanceState[i].currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(balanceState[i].currencyId);
            int ethValue = ethRate.convertToETH(
                assetRate.convertInternalToUnderlying(netLocalAssetValue)
            );

            netETHValue = netETHValue.add(ethValue);
        }

        return netETHValue;
    }

    function getFreeCollateralView(
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue,
        uint blockTime
    ) internal view returns (int) {
        uint groupIndex;
        int netETHValue;

        for (uint i; i < balanceState.length; i++) {
            // TODO: we can just fetch the balance storage here
            int netLocalAssetValue = balanceState[i].storedCashBalance;
            if (balanceState[i].storedPerpetualTokenBalance > 0) {
                PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioView(
                    balanceState[i].currencyId
                );
                // TODO: this will return an asset rate as well, so we can use it here
                int perpetualTokenValue = getPerpetualTokenAssetValue(
                    perpToken,
                    balanceState[i].storedPerpetualTokenBalance,
                    blockTime
                );
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            AssetRateParameters memory assetRate;
            if (cashGroups[groupIndex].currencyId == balanceState[i].currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                groupIndex += 1;
            } else {
                assetRate = AssetRate.buildAssetRateView(balanceState[i].currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(balanceState[i].currencyId);
            int ethValue = ethRate.convertToETH(
                assetRate.convertInternalToUnderlying(netLocalAssetValue)
            );

            netETHValue = netETHValue.add(ethValue);
        }

        return netETHValue;
    }

    function getPerpetualTokenAssetValue(
        PerpetualTokenPortfolio memory perpToken,
        int tokenBalance,
        uint blockTime
    ) internal view returns (int) {
        // TODO: if the currency id is in the list we make two stateful calls to get the asset rate...not very efficient
        // TODO: lots of storage reads to get this to work...can we make this more efficient?
        // TODO: nextMaturingAsset is not set to a predictable value here, how do we make that better, it should
        // be the reference time and then we just check if markets are initialized
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);

        (
            /* currencyId */,
            uint totalSupply,
            /* incentiveRate */
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(perpToken.tokenAddress);

        (
            int perpTokenPV,
            /* ifCashBitmap */
        ) = perpToken.getPerpetualTokenPV(accountContext, blockTime);

        // No overflow in totalSupply, stored as a uint96
        return tokenBalance.mul(perpTokenPV).div(int(totalSupply));
    }

    /**
     * @notice Ensures that all cash groups in a set of active assets are in the list of cash groups.
     * Cash groups can be in the active assets but not loaded yet if they have been previously traded.
     */
    function getAllCashGroupsStateful(
        PortfolioAsset[] memory assets
    ) internal returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        (
            CashGroupParameters[] memory cashGroups,
            MarketParameters[][] memory marketStates
        ) = allocateCashGroupsAndMarkets(assets);

        uint groupIndex;
        uint lastCurrencyId;
        for (uint i; i < assets.length; i++) {
            if (lastCurrencyId != assets[i].currencyId) {
                (
                    cashGroups[groupIndex],
                    marketStates[groupIndex]
                ) = CashGroup.buildCashGroupStateful(assets[i].currencyId);
                groupIndex += 1;
                lastCurrencyId = assets[i].currencyId;
            }
        }

        return (cashGroups, marketStates);
    }

    function getAllCashGroupsView(
        PortfolioAsset[] memory assets
    ) internal view returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        (
            CashGroupParameters[] memory cashGroups,
            MarketParameters[][] memory marketStates
        ) = allocateCashGroupsAndMarkets(assets);

        uint groupIndex;
        uint lastCurrencyId;
        for (uint i; i < assets.length; i++) {
            if (lastCurrencyId != assets[i].currencyId) {
                (
                    cashGroups[groupIndex],
                    marketStates[groupIndex]
                ) = CashGroup.buildCashGroupView(assets[i].currencyId);
                groupIndex += 1;
                lastCurrencyId = assets[i].currencyId;
            }
        }

        return (cashGroups, marketStates);
    }

    function allocateCashGroupsAndMarkets(
        PortfolioAsset[] memory assets
    ) private pure returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        uint groupIndex;
        uint lastCurrencyId;

        // Count the number of groups
        for (uint i; i < assets.length; i++) {
            if (lastCurrencyId != assets[i].currencyId) {
                groupIndex += 1;
                lastCurrencyId = assets[i].currencyId;
            }
        }

        return (new CashGroupParameters[](groupIndex), new MarketParameters[][](groupIndex));
    }

}
