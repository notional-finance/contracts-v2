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

struct FreeCollateralFactors {
    int netETHValue;
    bool updateContext;
    uint portfolioIndex;
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
    PortfolioAsset[] portfolio;
    AssetRateParameters assetRate;
}

struct LiquidationFactors {
    int collateralCash;
    int collateralAvailable;
    int collateralPerpetualTokenValue;
    ETHRate localETHRate;
    ETHRate collateralETHRate;
    CashGroupParameters collateralCashGroup;
    MarketParameters[] collateralMarkets;
}

library FreeCollateral {
    using SafeInt256 for int;
    using Bitmap for bytes;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;
    using PerpetualToken for PerpetualTokenPortfolio;

    function isActiveInPortfolio(bytes2 currencyBytes) private pure returns (bool) {
        return currencyBytes & AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG == AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG;
    }

    /**
     * @notice Checks if currency balances are active in the account returns them if true
     */
    function getCurrencyBalances(
        address account,
        bytes2 currencyBytes
    ) private view returns (int, int) {
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

    /**
     * @notice Calculates the perpetual token asset value with a haircut set by governance
     */
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


    /**
     * @notice Calculates portfolio and/or perpetual token values while using the supplied cash groups and
     * markets. The reason these are grouped together is because they both require storage reads of the same
     * values.
     */
    function getPortfolioAndPerpTokenValue(
        FreeCollateralFactors memory factors,
        int perpetualTokenBalance,
        uint blockTime
    ) internal view returns (int, int) {
        int netPortfolioValue;
        int perpetualTokenValue;

        // If the next asset matches the currency id then we need to calculate the cash group value
        if (factors.portfolioIndex < factors.portfolio.length
            && factors.portfolio[factors.portfolioIndex].currencyId == factors.cashGroup.currencyId) {
            (netPortfolioValue, factors.portfolioIndex) = AssetHandler.getNetCashGroupValue(
                factors.portfolio,
                factors.cashGroup,
                factors.markets,
                blockTime,
                factors.portfolioIndex
            );
        }

        if (perpetualTokenBalance > 0) {
            perpetualTokenValue = getPerpetualTokenAssetValue(
                factors.cashGroup,
                factors.markets,
                perpetualTokenBalance,
                blockTime
            );
        }

        return (netPortfolioValue, perpetualTokenValue);
    }

    /**
     * @notice Returns balance values for the bitmapped currency
     */
    function getBitmapBalanceValue(
        address account,
        uint blockTime,
        AccountStorage memory accountContext,
        FreeCollateralFactors memory factors
    ) internal view returns (int, int) {
        int perpetualTokenValue;
        (
            int cashBalance,
            int perpTokenBalance,
            /* lastIncentiveMint */
        ) = BalanceHandler.getBalanceStorage(account, accountContext.bitmapCurrencyId);

        if (perpTokenBalance > 0) {
            perpetualTokenValue = getPerpetualTokenAssetValue(
                factors.cashGroup,
                factors.markets,
                perpTokenBalance,
                blockTime
            );
        }

        return (cashBalance, perpetualTokenValue);
    }

    /**
     * @notice Returns portfolio value for the bitmapped currency
     */
    function getBitmapPortfolioValue(
        address account,
        uint blockTime,
        AccountStorage memory accountContext,
        FreeCollateralFactors memory factors
    ) internal view returns (int) {
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
        (int netPortfolioValue, bool bitmapHasDebt) = BitmapAssetsHandler.getifCashNetPresentValue(
            account,
            accountContext.bitmapCurrencyId,
            accountContext.nextSettleTime,
            blockTime,
            assetsBitmap,
            factors.cashGroup,
            factors.markets,
            true // risk adjusted
        );

        // Turns off has debt flag if it has changed
        bool contextHasAssetDebt = accountContext.hasDebt & AccountContextHandler.HAS_ASSET_DEBT == AccountContextHandler.HAS_ASSET_DEBT;
        if (bitmapHasDebt && !contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_ASSET_DEBT;
            factors.updateContext = true;
        } else if (!bitmapHasDebt && contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_ASSET_DEBT;
            factors.updateContext = true;
        }


        return netPortfolioValue;
    }

    /**
     * @notice Stateful version of get free collateral, returns the total net ETH value and true or false if the account
     * context needs to be updated.
     */
    function getFreeCollateralStateful(
        address account,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal returns (int, bool) {
        FreeCollateralFactors memory factors;
        bool hasCashDebt;

        if (accountContext.bitmapCurrencyId != 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
            (int netCashBalance, int perpetualTokenValue) = getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int portfolioBalance = getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int netLocalAssetValue = netCashBalance.add(perpetualTokenValue).add(portfolioBalance);
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(accountContext.bitmapCurrencyId);
            factors.netETHValue = ethRate.convertToETH(factors.cashGroup.assetRate.convertInternalToUnderlying(netLocalAssetValue));
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            uint currencyId = uint(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (int netLocalAssetValue, int perpTokenBalance) = getCurrencyBalances(account, currencyBytes);
            if (netLocalAssetValue < 0) hasCashDebt = true;

            if (isActiveInPortfolio(currencyBytes) || perpTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(currencyId);

                (int netPortfolioValue, int perpetualTokenValue) = getPortfolioAndPerpTokenValue(factors, perpTokenBalance, blockTime);
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(perpetualTokenValue);
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(factors.assetRate.convertInternalToUnderlying(netLocalAssetValue));
            factors.netETHValue = factors.netETHValue.add(ethValue);

            currencies = currencies << 16;
        }

        // Free collateral is the only method that examines all cash balances for an account at once. If there is no cash debt (i.e.
        // they have been repaid or settled via more debt) then this will turn off the flag. It's possible that this flag is out of
        // sync temporarily after a cash settlement and before the next free collateral check. The only downside for that is forcing
        // an account to do an extra free collateral check to turn off this setting.
        if (accountContext.hasDebt & AccountContextHandler.HAS_CASH_DEBT == AccountContextHandler.HAS_CASH_DEBT && !hasCashDebt) {
            accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_CASH_DEBT;
            factors.updateContext = true;
        }

        return (factors.netETHValue, factors.updateContext);
    }

    /**
     * @notice View version of getFreeCollateral, does not use the stateful version of build cash group and skips
     * all the update context logic.
     */
    function getFreeCollateralView(
        address account,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (int) {
        FreeCollateralFactors memory factors;

        if (accountContext.bitmapCurrencyId != 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupView(accountContext.bitmapCurrencyId);
            (int netCashBalance, int perpetualTokenValue) = getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int portfolioBalance = getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int netLocalAssetValue = netCashBalance.add(perpetualTokenValue).add(portfolioBalance);
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(accountContext.bitmapCurrencyId);
            factors.netETHValue = ethRate.convertToETH(factors.cashGroup.assetRate.convertInternalToUnderlying(netLocalAssetValue));
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            uint currencyId = uint(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (int netLocalAssetValue, int perpTokenBalance) = getCurrencyBalances(account, currencyBytes);

            if (isActiveInPortfolio(currencyBytes) || perpTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupView(currencyId);

                (int netPortfolioValue, int perpetualTokenValue) = getPortfolioAndPerpTokenValue(factors, perpTokenBalance, blockTime);
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(perpetualTokenValue);
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateView(currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(factors.assetRate.convertInternalToUnderlying(netLocalAssetValue));
            factors.netETHValue = factors.netETHValue.add(ethValue);

            currencies = currencies << 16;
        }

        return factors.netETHValue;
    }

    /**
     * @notice A version of getFreeCollateral used during liquidation to save off necessary additional information.
    */
    function getLiquidationFactors(
        address account,
        AccountStorage memory accountContext,
        uint blockTime,
        uint collateralCurrencyId
    ) internal returns (LiquidationFactors memory) {
        FreeCollateralFactors memory factors;
        LiquidationFactors memory liquidationFactors;

        if (accountContext.bitmapCurrencyId != 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
            (int netCashBalance, int perpetualTokenValue) = getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int portfolioBalance = getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int netLocalAssetValue = netCashBalance.add(perpetualTokenValue).add(portfolioBalance);
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(accountContext.bitmapCurrencyId);
            factors.netETHValue = ethRate.convertToETH(factors.cashGroup.assetRate.convertInternalToUnderlying(netLocalAssetValue));

            if (accountContext.bitmapCurrencyId == collateralCurrencyId) {
                liquidationFactors.collateralCash = netCashBalance;
                liquidationFactors.collateralCashGroup = factors.cashGroup;
                liquidationFactors.collateralMarkets = factors.markets;
                liquidationFactors.collateralPerpetualTokenValue = perpetualTokenValue;
                liquidationFactors.collateralAvailable = netLocalAssetValue;
                liquidationFactors.collateralETHRate = ethRate;
            }
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            uint currencyId = uint(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (int netLocalAssetValue, int perpTokenBalance) = getCurrencyBalances(account, currencyBytes);

            if (currencyId == collateralCurrencyId) {
                // Initially netLocalAssetValue is just the cash balance, reuse is required to get the stack to cooperate
                liquidationFactors.collateralCash = netLocalAssetValue;
            }

            if (isActiveInPortfolio(currencyBytes) || perpTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(currencyId);
                (int netPortfolioValue, int perpetualTokenValue) = getPortfolioAndPerpTokenValue(factors, perpTokenBalance, blockTime);

                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(perpetualTokenValue);
                factors.assetRate = factors.cashGroup.assetRate;

                if (currencyId == collateralCurrencyId) {
                    liquidationFactors.collateralCashGroup = factors.cashGroup;
                    liquidationFactors.collateralMarkets = factors.markets;
                    liquidationFactors.collateralPerpetualTokenValue = perpetualTokenValue;
                }
            } else {
                factors.assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(factors.assetRate.convertInternalToUnderlying(netLocalAssetValue));
            factors.netETHValue = factors.netETHValue.add(ethValue);

            if (currencyId == collateralCurrencyId) {
                // Here netLocalAssetValue is just the net total value in the current currency
                liquidationFactors.collateralAvailable = netLocalAssetValue;
                liquidationFactors.collateralETHRate = ethRate;
            }

            currencies = currencies << 16;
        }

        return liquidationFactors;
    }
}
