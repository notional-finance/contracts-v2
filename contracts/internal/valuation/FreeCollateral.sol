// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetHandler.sol";
import "../markets/CashGroup.sol";
import "./ExchangeRate.sol";
import "../../math/SafeInt256.sol";
import "../AccountContextHandler.sol";
import "../balances/BalanceHandler.sol";
import "../portfolio/PortfolioHandler.sol";

struct FreeCollateralFactors {
    int256 netETHValue;
    bool updateContext;
    uint256 portfolioIndex;
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
    PortfolioAsset[] portfolio;
    AssetRateParameters assetRate;
}

struct LiquidationFactors {
    address account;
    int256 netETHValue;
    int256 localAvailable;
    int256 collateralAvailable;
    int256 perpetualTokenValue;
    bytes6 perpetualTokenParameters;
    ETHRate localETHRate;
    ETHRate collateralETHRate;
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
}

library FreeCollateral {
    using SafeInt256 for int256;
    using Bitmap for bytes;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;
    using PerpetualToken for PerpetualTokenPortfolio;

    function isActiveInPortfolio(bytes2 currencyBytes) private pure returns (bool) {
        return
            currencyBytes & AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG ==
            AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG;
    }

    /// @notice Checks if currency balances are active in the account returns them if true

    function getCurrencyBalances(address account, bytes2 currencyBytes)
        private
        view
        returns (int256, int256)
    {
        if (
            currencyBytes & AccountContextHandler.ACTIVE_IN_BALANCES_FLAG ==
            AccountContextHandler.ACTIVE_IN_BALANCES_FLAG
        ) {
            uint256 currencyId =
                uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (int256 netLocalAssetValue, int256 perpetualTokenBalance, ) =
                /* lastIncentiveClaim */
                BalanceHandler.getBalanceStorage(account, currencyId);

            return (netLocalAssetValue, perpetualTokenBalance);
        }

        return (0, 0);
    }

    /// @notice Calculates the perpetual token asset value with a haircut set by governance

    function getPerpetualTokenAssetValue(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        int256 tokenBalance,
        uint256 blockTime
    ) internal view returns (int256, bytes6) {
        PerpetualTokenPortfolio memory perpToken =
            PerpetualToken.buildPerpetualTokenPortfolioNoCashGroup(cashGroup.currencyId);
        perpToken.cashGroup = cashGroup;
        perpToken.markets = markets;

        (
            int256 perpTokenPV, /* ifCashBitmap */

        ) = perpToken.getPerpetualTokenPV(blockTime);

        int256 perpTokenHaircutPV =
            tokenBalance
                .mul(perpTokenPV)
            // Haircut for perpetual token value
                .mul(int256(uint8(perpToken.parameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE])))
                .div(Constants.PERCENTAGE_DECIMALS)
                .div(perpToken.totalSupply);

        return (perpTokenHaircutPV, perpToken.parameters);
    }

    /// @notice Calculates portfolio and/or perpetual token values while using the supplied cash groups and
    /// markets. The reason these are grouped together is because they both require storage reads of the same
    /// values.

    function getPortfolioAndPerpTokenValue(
        FreeCollateralFactors memory factors,
        int256 perpetualTokenBalance,
        uint256 blockTime
    )
        internal
        view
        returns (
            int256,
            int256,
            bytes6
        )
    {
        int256 netPortfolioValue;
        int256 perpetualTokenValue;
        bytes6 perpTokenParameters;

        // If the next asset matches the currency id then we need to calculate the cash group value
        if (
            factors.portfolioIndex < factors.portfolio.length &&
            factors.portfolio[factors.portfolioIndex].currencyId == factors.cashGroup.currencyId
        ) {
            (netPortfolioValue, factors.portfolioIndex) = AssetHandler.getNetCashGroupValue(
                factors.portfolio,
                factors.cashGroup,
                factors.markets,
                blockTime,
                factors.portfolioIndex
            );
        }

        if (perpetualTokenBalance > 0) {
            (perpetualTokenValue, perpTokenParameters) = getPerpetualTokenAssetValue(
                factors.cashGroup,
                factors.markets,
                perpetualTokenBalance,
                blockTime
            );
        }

        return (netPortfolioValue, perpetualTokenValue, perpTokenParameters);
    }

    /// @notice Returns balance values for the bitmapped currency

    function getBitmapBalanceValue(
        address account,
        uint256 blockTime,
        AccountStorage memory accountContext,
        FreeCollateralFactors memory factors
    )
        internal
        view
        returns (
            int256,
            int256,
            bytes6
        )
    {
        int256 perpetualTokenValue;
        bytes6 perpetualTokenParameters;

        (int256 cashBalance, int256 perpTokenBalance, ) =
            /* lastIncentiveClaim */
            BalanceHandler.getBalanceStorage(account, accountContext.bitmapCurrencyId);

        if (perpTokenBalance > 0) {
            (perpetualTokenValue, perpetualTokenParameters) = getPerpetualTokenAssetValue(
                factors.cashGroup,
                factors.markets,
                perpTokenBalance,
                blockTime
            );
        }

        return (cashBalance, perpetualTokenValue, perpetualTokenParameters);
    }

    /// @notice Returns portfolio value for the bitmapped currency

    function getBitmapPortfolioValue(
        address account,
        uint256 blockTime,
        AccountStorage memory accountContext,
        FreeCollateralFactors memory factors
    ) internal view returns (int256) {
        bytes32 assetsBitmap =
            BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
        (int256 netPortfolioValue, bool bitmapHasDebt) =
            BitmapAssetsHandler.getifCashNetPresentValue(
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
        bool contextHasAssetDebt =
            accountContext.hasDebt & AccountContextHandler.HAS_ASSET_DEBT ==
                AccountContextHandler.HAS_ASSET_DEBT;
        if (bitmapHasDebt && !contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_ASSET_DEBT;
            factors.updateContext = true;
        } else if (!bitmapHasDebt && contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_ASSET_DEBT;
            factors.updateContext = true;
        }

        return netPortfolioValue;
    }

    /// @notice Stateful version of get free collateral, returns the total net ETH value and true or false if the account
    /// context needs to be updated.

    function getFreeCollateralStateful(
        address account,
        AccountStorage memory accountContext,
        uint256 blockTime
    ) internal returns (int256, bool) {
        FreeCollateralFactors memory factors;
        bool hasCashDebt;

        if (accountContext.bitmapCurrencyId != 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(
                accountContext.bitmapCurrencyId
            );
            (int256 netCashBalance, int256 perpetualTokenValue, ) =
                /* perpetualTokenParameters */
                getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioBalance =
                getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue =
                netCashBalance.add(perpetualTokenValue).add(portfolioBalance);
            ETHRate memory ethRate =
                ExchangeRate.buildExchangeRate(accountContext.bitmapCurrencyId);
            factors.netETHValue = ethRate.convertToETH(
                factors.cashGroup.assetRate.convertToUnderlying(netLocalAssetValue)
            );
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            uint256 currencyId =
                uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (int256 netLocalAssetValue, int256 perpTokenBalance) =
                getCurrencyBalances(account, currencyBytes);
            if (netLocalAssetValue < 0) hasCashDebt = true;

            if (isActiveInPortfolio(currencyBytes) || perpTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(currencyId);

                (int256 netPortfolioValue, int256 perpetualTokenValue, ) =
                    /* perpTokenParameters */
                    getPortfolioAndPerpTokenValue(factors, perpTokenBalance, blockTime);
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(
                    perpetualTokenValue
                );
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int256 ethValue =
                ethRate.convertToETH(factors.assetRate.convertToUnderlying(netLocalAssetValue));
            factors.netETHValue = factors.netETHValue.add(ethValue);

            currencies = currencies << 16;
        }

        // Free collateral is the only method that examines all cash balances for an account at once. If there is no cash debt (i.e.
        // they have been repaid or settled via more debt) then this will turn off the flag. It's possible that this flag is out of
        // sync temporarily after a cash settlement and before the next free collateral check. The only downside for that is forcing
        // an account to do an extra free collateral check to turn off this setting.
        if (
            accountContext.hasDebt & AccountContextHandler.HAS_CASH_DEBT ==
            AccountContextHandler.HAS_CASH_DEBT &&
            !hasCashDebt
        ) {
            accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_CASH_DEBT;
            factors.updateContext = true;
        }

        return (factors.netETHValue, factors.updateContext);
    }

    /// @notice View version of getFreeCollateral, does not use the stateful version of build cash group and skips
    /// all the update context logic.

    function getFreeCollateralView(
        address account,
        AccountStorage memory accountContext,
        uint256 blockTime
    ) internal view returns (int256) {
        FreeCollateralFactors memory factors;

        if (accountContext.bitmapCurrencyId != 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupView(
                accountContext.bitmapCurrencyId
            );
            (int256 netCashBalance, int256 perpetualTokenValue, ) =
                /* perpetualTokenParameters */
                getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioBalance =
                getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue =
                netCashBalance.add(perpetualTokenValue).add(portfolioBalance);
            ETHRate memory ethRate =
                ExchangeRate.buildExchangeRate(accountContext.bitmapCurrencyId);
            factors.netETHValue = ethRate.convertToETH(
                factors.cashGroup.assetRate.convertToUnderlying(netLocalAssetValue)
            );
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            uint256 currencyId =
                uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            (int256 netLocalAssetValue, int256 perpTokenBalance) =
                getCurrencyBalances(account, currencyBytes);

            if (isActiveInPortfolio(currencyBytes) || perpTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupView(currencyId);
                (int256 netPortfolioValue, int256 perpetualTokenValue, ) =
                    /* perpTokenParameters */
                    getPortfolioAndPerpTokenValue(factors, perpTokenBalance, blockTime);

                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(
                    perpetualTokenValue
                );
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateView(currencyId);
            }

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int256 ethValue =
                ethRate.convertToETH(factors.assetRate.convertToUnderlying(netLocalAssetValue));
            factors.netETHValue = factors.netETHValue.add(ethValue);

            currencies = currencies << 16;
        }

        return factors.netETHValue;
    }

    function calculateLiquidationAssetValue(
        FreeCollateralFactors memory factors,
        LiquidationFactors memory liquidationFactors,
        bytes2 currencyBytes,
        bool setLiquidationFactors,
        uint256 blockTime
    ) private returns (int256) {
        uint256 currencyId = uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
        (int256 netLocalAssetValue, int256 perpTokenBalance) =
            getCurrencyBalances(liquidationFactors.account, currencyBytes);

        if (isActiveInPortfolio(currencyBytes) || perpTokenBalance > 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(currencyId);
            (int256 netPortfolioValue, int256 perpetualTokenValue, bytes6 perpTokenParameters) =
                getPortfolioAndPerpTokenValue(factors, perpTokenBalance, blockTime);

            netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(perpetualTokenValue);
            factors.assetRate = factors.cashGroup.assetRate;

            // If collateralCurrencyId is set to zero then this is a local currency liquidation
            if (setLiquidationFactors) {
                liquidationFactors.cashGroup = factors.cashGroup;
                liquidationFactors.markets = factors.markets;
                liquidationFactors.perpetualTokenParameters = perpTokenParameters;
                liquidationFactors.perpetualTokenValue = perpetualTokenValue;
            }
        } else {
            factors.assetRate = AssetRate.buildAssetRateStateful(currencyId);
        }

        return netLocalAssetValue;
    }

    /// @notice A version of getFreeCollateral used during liquidation to save off necessary additional information.

    function getLiquidationFactors(
        address account,
        AccountStorage memory accountContext,
        uint256 blockTime,
        uint256 localCurrencyId,
        uint256 collateralCurrencyId
    ) internal returns (LiquidationFactors memory, PortfolioAsset[] memory) {
        FreeCollateralFactors memory factors;
        LiquidationFactors memory liquidationFactors;
        // This is only set to reduce the stack size
        liquidationFactors.account = account;

        if (accountContext.bitmapCurrencyId != 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(
                accountContext.bitmapCurrencyId
            );
            (int256 netCashBalance, int256 perpetualTokenValue, bytes6 perpetualTokenParameters) =
                getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioBalance =
                getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue =
                netCashBalance.add(perpetualTokenValue).add(portfolioBalance);
            ETHRate memory ethRate =
                ExchangeRate.buildExchangeRate(accountContext.bitmapCurrencyId);
            factors.netETHValue = ethRate.convertToETH(
                factors.cashGroup.assetRate.convertToUnderlying(netLocalAssetValue)
            );

            // If the bitmap currency id can only ever be the local currency where debt is held. During enable bitmap we check that
            // the account has no assets in their portfolio and no cash debts.
            if (accountContext.bitmapCurrencyId == localCurrencyId) {
                liquidationFactors.cashGroup = factors.cashGroup;
                liquidationFactors.markets = factors.markets;
                liquidationFactors.localAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;

                // This will be the case during local currency or local fCash liquidation
                if (collateralCurrencyId == 0) {
                    liquidationFactors.perpetualTokenValue = perpetualTokenValue;
                    liquidationFactors.perpetualTokenParameters = perpetualTokenParameters;
                }
            }
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);

            // This next bit of code here is annoyingly structured to get around stack size issues
            bool setLiquidationFactors;
            {
                uint256 tempId =
                    uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
                setLiquidationFactors =
                    (tempId == localCurrencyId && collateralCurrencyId == 0) ||
                    tempId == collateralCurrencyId;
            }
            int256 netLocalAssetValue =
                calculateLiquidationAssetValue(
                    factors,
                    liquidationFactors,
                    currencyBytes,
                    setLiquidationFactors,
                    blockTime
                );

            uint256 currencyId =
                uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int256 ethValue =
                ethRate.convertToETH(factors.assetRate.convertToUnderlying(netLocalAssetValue));
            factors.netETHValue = factors.netETHValue.add(ethValue);

            if (currencyId == collateralCurrencyId) {
                liquidationFactors.collateralAvailable = netLocalAssetValue;
                liquidationFactors.collateralETHRate = ethRate;
            } else if (currencyId == localCurrencyId) {
                liquidationFactors.localAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;
            }

            currencies = currencies << 16;
        }

        liquidationFactors.netETHValue = factors.netETHValue;
        require(liquidationFactors.netETHValue < 0, "Sufficient collateral");

        // Refetch the portfolio if it exists, AssetHandler.getNetCashValue updates values in memory to do fCash
        // netting which will make further calculations incurreoct.
        if (accountContext.assetArrayLength > 0) {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }

        return (liquidationFactors, factors.portfolio);
    }
}
