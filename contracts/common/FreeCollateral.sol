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

    function getCurrencyBalances(
        address account,
        bytes2 currencyBytes
    ) internal view returns (int, int) {
        if (currencyBytes & AccountContextHandler.ACTIVE_IN_BALANCES_FLAG 
                == AccountContextHandler.ACTIVE_IN_BALANCES_FLAG) {
            uint currencyId = uint(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (
                int netLocalAssetValue,
                int perpetualTokenBalance,
                /* lastIncentiveMint */
            ) = BalanceHandler.getBalanceStorage(account, currencyId);

            return (netLocalAssetValue, perpetualTokenBalance);
        }

        return (0, 0);
    }

    function getPerpetualTokenAssetValue(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        int tokenBalance,
        uint blockTime
    ) internal view returns (int) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioNoCashGroup(
            cashGroup.currencyId
        );
        perpToken.cashGroup = cashGroup;
        perpToken.markets = markets;

        (int perpTokenPV, /* ifCashBitmap */) = perpToken.getPerpetualTokenPV(blockTime);

        return tokenBalance
            .mul(perpTokenPV)
            // Haircut for perpetual token value
            .mul(int(uint8(perpToken.parameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE])))
            .div(CashGroup.PERCENTAGE_DECIMALS)
            .div(perpToken.totalSupply);
    }


    function getPortfolioAndPerpTokenValue(
        bytes2 currencyBytes,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint portfolioIndex,
        int perpTokenBalance,
        uint blockTime
    ) internal view returns (int, uint, bool) {
        int netAssetValue;
        bool hasLiquidityTokens;

        if (currencyBytes & AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG == AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG) {
            (netCashGroupValue, portfolioIndex, hasLiquidityTokens) = AssetHandler.getNetCashGroupValue(
                portfolio,
                cashGroup,
                markets,
                blockTime,
                portfolioIndex,
                true
            );

            netAssetValue = netAssetValue.add(netCashGroupValue);
        }

        if (perpTokenBalance > 0) {
            int perpetualTokenValue = getPerpetualTokenAssetValue(
                cashGroup,
                markets,
                perpTokenBalance,
                blockTime
            );

            netAssetValue = netAssetValue.add(perpetualTokenValue);
        }

        return (netAssetValue, portfolioIndex, hasLiquidityTokens);
    }

    function getBitmapCurrencyValue(
        address account,
        uint currencyId,
        uint blockTime,
        AccountStorage memory accountContext
    ) internal view returns (int, bool) {
        (
            CashGroupParameter memory cashGroup,
            MarketParameters[] memory markets
        ) = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
        bool updateContext = false;

        (
            int netLocalAssetValue,
            int perpTokenBalance,
            /* lastIncentiveMint */
        ) = BalanceHandler.getBalanceStorage(account, currencyId);

        if (perpTokenBalance > 0) {
            int perpetualTokenValue = getPerpetualTokenAssetValue(
                cashGroup,
                markets,
                perpTokenBalance,
                blockTime
            );
            netAssetValue = netAssetValue.add(perpetualTokenValue);
        }

        bool bitmapHasDebt;
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
        (int netPortfolioValue, bool bitmapHasDebt) = BitmapAssetsHandler.getifCashNetPresentValue(
            account,
            accountContext.bitmapCurrencyId,
            accountContext.nextSettleTime,
            blockTime,
            assetsBitmap,
            cashGroup,
            markets,
            true // risk adjusted
        );
        netAssetValue = netAssetValue.add(netPortfolioValue);

        // Turns off has debt flag if it has changed
        bool contextHasAssetDebt = accountContext.hasDebt & AccountContextHandler.HAS_ASSET_DEBT == AccountContextHandler.HAS_ASSET_DEBT;
        if (bitmapHasDebt && !contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_ASSET_DEBT;
            updateContext = true;
        } else if (!bitmapHasDebt && contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_ASSET_DEBT;
            updateContext = true;
        }

        ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
        int ethValue = ethRate.convertToETH(assetRate.convertInternalToUnderlying(netLocalAssetValue));

        return (ethValue, updateContext);
    }

    function getFreeCollateralV2(
        address account,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal returns (int, bool) {
        int netETHValue;
        if (accountContext.bitmapCurrencyId != 0) {
            (netETHValue, updateContext) = getBitmapCurrencyValue(account,
                blockTime,
                accountContext
            );
        }

        bytes18 currencies = accountContext.activeCurrencies;
        PortfolioAsset[] memory portfolio;
        uint portfolioIndex;
        AssetRateParameters memory assetRate;

        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            (int netLocalAssetValue, int perpTokenBalance) = getCurrencyBalances(account, currencyBytes);

            if (currencyBytes & AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG 
                    == AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG || perpTokenBalance > 0) {
                (
                    CashGroupParameters memory cashGroup,
                    MarketParameters[] memory markets
                ) = CashGroup.buildCashGroupStateful(currencyId);

                int netAssetValue;
                (netAssetValue, portfolioIndex, /* hasLiquidityTokens */) = getPortfolioAndPerpTokenValue(
                    currencyBytes,
                    cashGroup,
                    markets,
                    portfolioIndex,
                    perpTokenBalance,
                    blockTime
                );

                assetRate = cashGroup.assetRate;
            } else {
                assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(assetRate.convertInternalToUnderlying(netLocalAssetValue));
            netETHValue = netETHValue.add(ethValue);

            currencies = currencies << 16;
        }
    }
}
