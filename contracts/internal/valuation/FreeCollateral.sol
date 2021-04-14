// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetHandler.sol";
import "./ExchangeRate.sol";
import "../markets/CashGroup.sol";
import "../AccountContextHandler.sol";
import "../balances/BalanceHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "../../math/SafeInt256.sol";

library FreeCollateral {
    using SafeInt256 for int256;
    using Bitmap for bytes;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;
    using nTokenHandler for nTokenPortfolio;

    /// @dev This is only used within the library to clean up the stack
    struct FreeCollateralFactors {
        int256 netETHValue;
        bool updateContext;
        uint256 portfolioIndex;
        CashGroupParameters cashGroup;
        MarketParameters[] markets;
        PortfolioAsset[] portfolio;
        AssetRateParameters assetRate;
    }

    /// @notice Checks if an asset is active in the portfolio
    function _isActiveInPortfolio(bytes2 currencyBytes) private pure returns (bool) {
        return currencyBytes & Constants.ACTIVE_IN_PORTFOLIO == Constants.ACTIVE_IN_PORTFOLIO;
    }

    /// @notice Checks if currency balances are active in the account returns them if true
    function _getCurrencyBalances(address account, bytes2 currencyBytes)
        private
        view
        returns (int256, int256)
    {
        if (currencyBytes & Constants.ACTIVE_IN_BALANCES == Constants.ACTIVE_IN_BALANCES) {
            uint256 currencyId =
                uint256(uint16(currencyBytes & AccountContextHandler.UNMASK_FLAGS));
            // prettier-ignore
            (
                int256 netLocalAssetValue,
                int256 nTokenBalance,
                /* lastIncentiveClaim */
            ) = BalanceHandler.getBalanceStorage(account, currencyId);

            return (netLocalAssetValue, nTokenBalance);
        }

        return (0, 0);
    }

    /// @notice Calculates the nToken asset value with a haircut set by governance
    function _getNTokenHaircutValue(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        int256 tokenBalance,
        uint256 blockTime
    ) internal view returns (int256, bytes6) {
        nTokenPortfolio memory nToken =
            nTokenHandler.buildNTokenPortfolioNoCashGroup(cashGroup.currencyId);
        nToken.cashGroup = cashGroup;
        nToken.markets = markets;

        // prettier-ignore
        (
            int256 nTokenPV,
            /* ifCashBitmap */
        ) = nToken.getNTokenPV(blockTime);

        int256 nTokenHaircutPV =
            tokenBalance
                .mul(nTokenPV)
                .mul(int256(uint8(nToken.parameters[Constants.PV_HAIRCUT_PERCENTAGE])))
                .div(Constants.PERCENTAGE_DECIMALS)
                .div(nToken.totalSupply);

        return (nTokenHaircutPV, nToken.parameters);
    }

    /// @notice Calculates portfolio and/or nToken values while using the supplied cash groups and
    /// markets. The reason these are grouped together is because they both require storage reads of the same
    /// values.
    function _getPortfolioAndNTokenValue(
        FreeCollateralFactors memory factors,
        int256 nTokenBalance,
        uint256 blockTime
    )
        private
        view
        returns (
            int256 netPortfolioValue,
            int256 nTokenValue,
            bytes6 nTokenParameters
        )
    {
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

        if (nTokenBalance > 0) {
            (nTokenValue, nTokenParameters) = _getNTokenHaircutValue(
                factors.cashGroup,
                factors.markets,
                nTokenBalance,
                blockTime
            );
        }
    }

    /// @notice Returns balance values for the bitmapped currency
    function _getBitmapBalanceValue(
        address account,
        uint256 blockTime,
        AccountStorage memory accountContext,
        FreeCollateralFactors memory factors
    )
        private
        view
        returns (
            int256 cashBalance,
            int256 nTokenValue,
            bytes6 nTokenParameters
        )
    {
        int256 nTokenBalance;
        // prettier-ignore
        (
            cashBalance,
            nTokenBalance, 
            /* lastIncentiveClaim */
        ) = BalanceHandler.getBalanceStorage(account, accountContext.bitmapCurrencyId);

        if (nTokenBalance > 0) {
            (nTokenValue, nTokenParameters) = _getNTokenHaircutValue(
                factors.cashGroup,
                factors.markets,
                nTokenBalance,
                blockTime
            );
        }
    }

    /// @notice Returns portfolio value for the bitmapped currency
    function _getBitmapPortfolioValue(
        address account,
        uint256 blockTime,
        AccountStorage memory accountContext,
        FreeCollateralFactors memory factors
    ) private view returns (int256) {
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
            accountContext.hasDebt & Constants.HAS_ASSET_DEBT == Constants.HAS_ASSET_DEBT;
        if (bitmapHasDebt && !contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
            factors.updateContext = true;
        } else if (!bitmapHasDebt && contextHasAssetDebt) {
            accountContext.hasDebt = accountContext.hasDebt & ~Constants.HAS_ASSET_DEBT;
            factors.updateContext = true;
        }

        return netPortfolioValue;
    }

    function _updateNetETHValue(
        uint256 currencyId,
        int256 netLocalAssetValue,
        FreeCollateralFactors memory factors
    ) private view returns (ETHRate memory) {
        ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
        factors.netETHValue = ethRate.convertToETH(
            factors.cashGroup.assetRate.convertToUnderlying(netLocalAssetValue)
        );

        return ethRate;
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
            // prettier-ignore
            (
                int256 netCashBalance,
                int256 nTokenValue,
                /* nTokenParameters */
            ) = _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioValue =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue = netCashBalance.add(nTokenValue).add(portfolioValue);
            _updateNetETHValue(accountContext.bitmapCurrencyId, netLocalAssetValue, factors);
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

            (int256 netLocalAssetValue, int256 nTokenBalance) =
                _getCurrencyBalances(account, currencyBytes);
            if (netLocalAssetValue < 0) hasCashDebt = true;

            if (_isActiveInPortfolio(currencyBytes) || nTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(currencyId);

                // prettier-ignore
                (
                    int256 netPortfolioValue,
                    int256 nTokenValue,
                    /* nTokenParameters */
                ) = _getPortfolioAndNTokenValue(factors, nTokenBalance, blockTime);
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(nTokenValue);
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            _updateNetETHValue(currencyId, netLocalAssetValue, factors);
            currencies = currencies << 16;
        }

        // Free collateral is the only method that examines all cash balances for an account at once. If there is no cash debt (i.e.
        // they have been repaid or settled via more debt) then this will turn off the flag. It's possible that this flag is out of
        // sync temporarily after a cash settlement and before the next free collateral check. The only downside for that is forcing
        // an account to do an extra free collateral check to turn off this setting.
        if (
            accountContext.hasDebt & Constants.HAS_CASH_DEBT == Constants.HAS_CASH_DEBT &&
            !hasCashDebt
        ) {
            accountContext.hasDebt = accountContext.hasDebt & ~Constants.HAS_CASH_DEBT;
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
            // prettier-ignore
            (
                int256 netCashBalance,
                int256 nTokenValue,
                /* nTokenParameters */
            ) = _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioBalance =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue = netCashBalance.add(nTokenValue).add(portfolioBalance);
            _updateNetETHValue(accountContext.bitmapCurrencyId, netLocalAssetValue, factors);
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
            (int256 netLocalAssetValue, int256 nTokenBalance) =
                _getCurrencyBalances(account, currencyBytes);

            if (_isActiveInPortfolio(currencyBytes) || nTokenBalance > 0) {
                (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupView(currencyId);
                // prettier-ignore
                (
                    int256 netPortfolioValue,
                    int256 nTokenValue,
                    /* nTokenParameters */
                ) = _getPortfolioAndNTokenValue(factors, nTokenBalance, blockTime);

                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(nTokenValue);
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateView(currencyId);
            }

            _updateNetETHValue(currencyId, netLocalAssetValue, factors);
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
        (int256 netLocalAssetValue, int256 nTokenBalance) =
            _getCurrencyBalances(liquidationFactors.account, currencyBytes);

        if (_isActiveInPortfolio(currencyBytes) || nTokenBalance > 0) {
            (factors.cashGroup, factors.markets) = CashGroup.buildCashGroupStateful(currencyId);
            (int256 netPortfolioValue, int256 nTokenValue, bytes6 nTokenParameters) =
                _getPortfolioAndNTokenValue(factors, nTokenBalance, blockTime);

            netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue).add(nTokenValue);
            factors.assetRate = factors.cashGroup.assetRate;

            // If collateralCurrencyId is set to zero then this is a local currency liquidation
            if (setLiquidationFactors) {
                liquidationFactors.cashGroup = factors.cashGroup;
                liquidationFactors.markets = factors.markets;
                liquidationFactors.nTokenParameters = nTokenParameters;
                liquidationFactors.nTokenValue = nTokenValue;
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
            (int256 netCashBalance, int256 nTokenValue, bytes6 nTokenParameters) =
                _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioBalance =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue = netCashBalance.add(nTokenValue).add(portfolioBalance);
            ETHRate memory ethRate =
                _updateNetETHValue(accountContext.bitmapCurrencyId, netLocalAssetValue, factors);

            // If the bitmap currency id can only ever be the local currency where debt is held. During enable bitmap we check that
            // the account has no assets in their portfolio and no cash debts.
            if (accountContext.bitmapCurrencyId == localCurrencyId) {
                liquidationFactors.cashGroup = factors.cashGroup;
                liquidationFactors.markets = factors.markets;
                liquidationFactors.localAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;

                // This will be the case during local currency or local fCash liquidation
                if (collateralCurrencyId == 0) {
                    liquidationFactors.nTokenValue = nTokenValue;
                    liquidationFactors.nTokenParameters = nTokenParameters;
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
            ETHRate memory ethRate = _updateNetETHValue(currencyId, netLocalAssetValue, factors);

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
