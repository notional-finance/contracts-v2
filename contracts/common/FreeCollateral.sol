// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetHandler.sol";
import "./CashGroup.sol";
import "./ExchangeRate.sol";
import "../math/SafeInt256.sol";
import "../storage/AccountContextHandler.sol";
import "../storage/BalanceHandler.sol";
import "../storage/PortfolioHandler.sol";

library FreeCollateral {
    using SafeInt256 for int;
    using Bitmap for bytes;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;
    using PerpetualToken for PerpetualTokenPortfolio;

    function getNetPortfolioValueStateful(
        address account,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal returns (int[] memory, CashGroupParameters[] memory, bool) {
        if (accountContext.bitmapCurrencyId != 0) {
            CashGroupParameters[] memory cashGroups = new CashGroupParameters[](1);
            MarketParameters[] memory markets;
            (cashGroups[0], markets) = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
            int[] memory netPortfolioValue = new int[](1);
            bool updateContext = false;

            bool bitmapHasDebt;
            bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
            (netPortfolioValue[0], bitmapHasDebt) = BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime,
                blockTime,
                assetsBitmap,
                cashGroups[0],
                markets,
                true // risk adjusted
            );

            // Turns off has debt flag if it has changed
            bool contextHasAssetDebt = accountContext.hasDebt & AccountContextHandler.HAS_ASSET_DEBT == AccountContextHandler.HAS_ASSET_DEBT;
            if (bitmapHasDebt && !contextHasAssetDebt) {
                accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_ASSET_DEBT;
                updateContext = true;
            } else if (!bitmapHasDebt && contextHasAssetDebt) {
                accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_ASSET_DEBT;
                updateContext = true;
            }

            return (netPortfolioValue, cashGroups, updateContext);
        } else {
            PortfolioAsset[] memory portfolio = PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
            (
                CashGroupParameters[] memory cashGroups,
                MarketParameters[][] memory marketStates
            ) = getAllCashGroupsStateful(portfolio);

            int[] memory netPortfolioValue = AssetHandler.getPortfolioValue(
                portfolio,
                cashGroups,
                marketStates,
                blockTime,
                true // Must be risk adjusted
            );

            // No need to update context in this branch
            return (netPortfolioValue, cashGroups, false);
        }
    }

    function getNetPortfolioValueView(
        address account,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (int[] memory, CashGroupParameters[] memory) {
        if (accountContext.bitmapCurrencyId != 0) {
            CashGroupParameters[] memory cashGroups = new CashGroupParameters[](1);
            MarketParameters[] memory markets;
            (cashGroups[0], markets) = CashGroup.buildCashGroupView(accountContext.bitmapCurrencyId);
            int[] memory netPortfolioValue = new int[](1);

            (netPortfolioValue[0], /* bitmapHasDebt */) = BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime,
                blockTime,
                BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId),
                cashGroups[0],
                markets,
                true // risk adjusted
            );

            // No need to update context in this branch
            return (netPortfolioValue, cashGroups);
        } else {
            PortfolioAsset[] memory portfolio = PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
            (
                CashGroupParameters[] memory cashGroups,
                MarketParameters[][] memory marketStates
            ) = getAllCashGroupsView(portfolio);

            int[] memory netPortfolioValue = AssetHandler.getPortfolioValue(
                portfolio,
                cashGroups,
                marketStates,
                blockTime,
                true // Must be risk adjusted
            );

            return (netPortfolioValue, cashGroups);
        }
    }

    /**
     * @notice Aggregates the portfolio value with cash balances to get the net free collateral value.
     */
    function getFreeCollateralStateful(
        address account,
        AccountStorage memory accountContext,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue,
        uint blockTime
    ) internal returns (int, bool) {
        uint groupIndex;
        int netETHValue;
        bytes20 currencies = accountContext.getActiveCurrencyBytes();
        bool hasCashDebt;

        while (currencies != 0) {
            uint currencyId = uint(uint16(bytes2(currencies)));
            (
                int netLocalAssetValue,
                int perpTokenBalance,
                /* */
            ) = BalanceHandler.getBalanceStorage(account, currencyId);
            hasCashDebt = hasCashDebt || netLocalAssetValue < 0;

            AssetRateParameters memory assetRate;
            if (cashGroups.length > groupIndex && cashGroups[groupIndex].currencyId == currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                assetRate = cashGroups[groupIndex].assetRate;
                groupIndex += 1;
            } else {
                assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            if (perpTokenBalance > 0) {
                PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(
                    currencyId
                );
                // TODO: this will return an asset rate as well, so we can use it here
                int perpetualTokenValue = getPerpetualTokenAssetValue(
                    perpToken,
                    perpTokenBalance,
                    blockTime
                );
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(assetRate.convertInternalToUnderlying(netLocalAssetValue));
            netETHValue = netETHValue.add(ethValue);

            currencies = currencies << 16;
        }

        return (netETHValue, hasCashDebt);
    }

    function getFreeCollateralView(
        address account,
        AccountStorage memory accountContext,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue,
        uint blockTime
    ) internal view returns (int) {
        uint groupIndex;
        int netETHValue;
        bytes20 currencies = accountContext.getActiveCurrencyBytes();

        while (currencies != 0) {
            uint currencyId = uint(uint16(bytes2(currencies)));
            (
                int netLocalAssetValue,
                int perpTokenBalance,
                /* */
            ) = BalanceHandler.getBalanceStorage(account, currencyId);

            AssetRateParameters memory assetRate;
            if (cashGroups.length > groupIndex && cashGroups[groupIndex].currencyId == currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                assetRate = cashGroups[groupIndex].assetRate;
                groupIndex += 1;
            } else {
                assetRate = AssetRate.buildAssetRateView(currencyId);
            }

            if (perpTokenBalance > 0) {
                PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioView(
                    currencyId
                );
                // TODO: this will return an asset rate as well, so we can use it here
                int perpetualTokenValue = getPerpetualTokenAssetValue(
                    perpToken,
                    perpTokenBalance,
                    blockTime
                );
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(assetRate.convertInternalToUnderlying(netLocalAssetValue));
            netETHValue = netETHValue.add(ethValue);

            currencies = currencies << 16;
        }

        return netETHValue;
    }

    function getPerpetualTokenAssetValue(
        PerpetualTokenPortfolio memory perpToken,
        int tokenBalance,
        uint blockTime
    ) internal view returns (int) {
        (int perpTokenPV, /* ifCashBitmap */) = perpToken.getPerpetualTokenPV(blockTime);

        return tokenBalance
            .mul(perpTokenPV)
            // Haircut for perpetual token value
            .mul(int(uint8(perpToken.parameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE])))
            .div(CashGroup.PERCENTAGE_DECIMALS)
            .div(perpToken.totalSupply);
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
