// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "./AssetHandler.sol";
import "./ExchangeRate.sol";
import "../markets/CashGroup.sol";
import "../AccountContextHandler.sol";
import "../balances/BalanceHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/UserDefinedType.sol";

library FreeCollateral {
    using UserDefinedType for IA;
    using UserDefinedType for NT;
    using UserDefinedType for IU;
    using SafeInt256 for int256;
    using Bitmap for bytes;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;
    using nTokenHandler for nTokenPortfolio;

    /// @dev This is only used within the library to clean up the stack
    struct FreeCollateralFactors {
        IU netETHValue;
        bool updateContext;
        uint256 portfolioIndex;
        CashGroupParameters cashGroup;
        MarketParameters market;
        PortfolioAsset[] portfolio;
        AssetRateParameters assetRate;
        nTokenPortfolio nToken;
    }

    /// @notice Checks if an asset is active in the portfolio
    function _isActiveInPortfolio(bytes2 currencyBytes) private pure returns (bool) {
        return currencyBytes & Constants.ACTIVE_IN_PORTFOLIO == Constants.ACTIVE_IN_PORTFOLIO;
    }

    /// @notice Checks if currency balances are active in the account returns them if true
    /// @return cash balance, nTokenBalance
    function _getCurrencyBalances(address account, bytes2 currencyBytes)
        private
        view
        returns (IA, NT)
    {
        if (currencyBytes & Constants.ACTIVE_IN_BALANCES == Constants.ACTIVE_IN_BALANCES) {
            uint256 currencyId = uint16(currencyBytes & Constants.UNMASK_FLAGS);
            // prettier-ignore
            (
                IA cashBalance,
                NT nTokenBalance,
                /* lastClaimTime */,
                /* lastClaimIntegralSupply */
            ) = BalanceHandler.getBalanceStorage(account, currencyId);

            return (cashBalance, nTokenBalance);
        }

        return (IA.wrap(0), NT.wrap(0));
    }

    /// @notice Calculates the nToken asset value with a haircut set by governance
    /// @return the value of the account's nTokens after haircut, the nToken parameters
    function _getNTokenHaircutAssetPV(
        CashGroupParameters memory cashGroup,
        nTokenPortfolio memory nToken,
        NT tokenBalance,
        uint256 blockTime
    ) internal view returns (IA, bytes6) {
        nToken.loadNTokenPortfolioNoCashGroup(cashGroup.currencyId);
        nToken.cashGroup = cashGroup;

        IA nTokenAssetPV = nToken.getNTokenAssetPV(blockTime);

        // (tokenBalance * nTokenValue * haircut) / totalSupply
        IA nTokenHaircutAssetPV = nTokenAssetPV.scaleDouble(
            NT.unwrap(tokenBalance),
            int256(uint256(uint8(nToken.parameters[Constants.PV_HAIRCUT_PERCENTAGE]))),
            NT.unwrap(nToken.totalSupply),
            Constants.PERCENTAGE_DECIMALS
        );

        // nToken.parameters is returned for use in liquidation
        return (nTokenHaircutAssetPV, nToken.parameters);
    }

    /// @notice Calculates portfolio and/or nToken values while using the supplied cash groups and
    /// markets. The reason these are grouped together is because they both require storage reads of the same
    /// values.
    function _getPortfolioAndNTokenAssetValue(
        FreeCollateralFactors memory factors,
        NT nTokenBalance,
        uint256 blockTime
    )
        private
        view
        returns (
            IA netPortfolioValue,
            IA nTokenHaircutAssetValue,
            bytes6 nTokenParameters
        )
    {
        // If the next asset matches the currency id then we need to calculate the cash group value
        if (
            factors.portfolioIndex < factors.portfolio.length &&
            factors.portfolio[factors.portfolioIndex].currencyId == factors.cashGroup.currencyId
        ) {
            // netPortfolioValue is in asset cash
            (netPortfolioValue, factors.portfolioIndex) = AssetHandler.getNetCashGroupValue(
                factors.portfolio,
                factors.cashGroup,
                factors.market,
                blockTime,
                factors.portfolioIndex
            );
        } else {
            netPortfolioValue = IA.wrap(0);
        }

        if (nTokenBalance.isPosNotZero()) {
            (nTokenHaircutAssetValue, nTokenParameters) = _getNTokenHaircutAssetPV(
                factors.cashGroup,
                factors.nToken,
                nTokenBalance,
                blockTime
            );
        } else {
            nTokenHaircutAssetValue = IA.wrap(0);
            nTokenParameters = 0;
        }
    }

    /// @notice Returns balance values for the bitmapped currency
    function _getBitmapBalanceValue(
        address account,
        uint256 blockTime,
        AccountContext memory accountContext,
        FreeCollateralFactors memory factors
    )
        private
        view
        returns (
            IA cashBalance,
            IA nTokenHaircutAssetValue,
            bytes6 nTokenParameters
        )
    {
        NT nTokenBalance;
        // prettier-ignore
        (
            cashBalance,
            nTokenBalance, 
            /* lastClaimTime */,
            /* lastClaimIntegralSupply */
        ) = BalanceHandler.getBalanceStorage(account, accountContext.bitmapCurrencyId);

        if (nTokenBalance.isPosNotZero()) {
            (nTokenHaircutAssetValue, nTokenParameters) = _getNTokenHaircutAssetPV(
                factors.cashGroup,
                factors.nToken,
                nTokenBalance,
                blockTime
            );
        } else {
            nTokenHaircutAssetValue = IA.wrap(0);
        }
    }

    /// @notice Returns portfolio value for the bitmapped currency
    function _getBitmapPortfolioValue(
        address account,
        uint256 blockTime,
        AccountContext memory accountContext,
        FreeCollateralFactors memory factors
    ) private view returns (IA) {
        (IU netPortfolioValueUnderlying, bool bitmapHasDebt) =
            BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime,
                blockTime,
                factors.cashGroup,
                true // risk adjusted
            );

        // Turns off has debt flag if it has changed
        bool contextHasAssetDebt =
            accountContext.hasDebt & Constants.HAS_ASSET_DEBT == Constants.HAS_ASSET_DEBT;
        if (bitmapHasDebt && !contextHasAssetDebt) {
            // Turn on has debt
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
            factors.updateContext = true;
        } else if (!bitmapHasDebt && contextHasAssetDebt) {
            // Turn off has debt
            accountContext.hasDebt = accountContext.hasDebt & ~Constants.HAS_ASSET_DEBT;
            factors.updateContext = true;
        }

        // Return asset cash value
        return factors.cashGroup.assetRate.convertFromUnderlying(netPortfolioValueUnderlying);
    }

    function _updateNetETHValue(
        uint256 currencyId,
        IA netLocalAssetValue,
        FreeCollateralFactors memory factors
    ) private view returns (ETHRate memory) {
        ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
        // Converts to underlying first, ETH exchange rates are in underlying
        factors.netETHValue = factors.netETHValue.add(
            ethRate.convertToETH(factors.assetRate.convertToUnderlying(netLocalAssetValue))
        );

        return ethRate;
    }

    /// @notice Stateful version of get free collateral, returns the total net ETH value and true or false if the account
    /// context needs to be updated.
    function getFreeCollateralStateful(
        address account,
        AccountContext memory accountContext,
        uint256 blockTime
    ) internal returns (IU, bool) {
        FreeCollateralFactors memory factors;
        bool hasCashDebt;

        if (accountContext.isBitmapEnabled()) {
            factors.cashGroup = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);

            // prettier-ignore
            (
                IA netCashBalance,
                IA nTokenHaircutAssetValue,
                /* nTokenParameters */
            ) = _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            if (netCashBalance.isNegNotZero()) hasCashDebt = true;

            IA portfolioAssetValue =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);
            IA netLocalAssetValue =
                netCashBalance.add(nTokenHaircutAssetValue).add(portfolioAssetValue);

            factors.assetRate = factors.cashGroup.assetRate;
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
            uint16 currencyId = uint16(currencyBytes & Constants.UNMASK_FLAGS);

            (IA netLocalAssetValue, NT nTokenBalance) =
                _getCurrencyBalances(account, currencyBytes);
            if (netLocalAssetValue.isNegNotZero()) hasCashDebt = true;

            if (_isActiveInPortfolio(currencyBytes) || nTokenBalance.isPosNotZero()) {
                factors.cashGroup = CashGroup.buildCashGroupStateful(currencyId);

                // prettier-ignore
                (
                    IA netPortfolioAssetValue,
                    IA nTokenHaircutAssetValue,
                    /* nTokenParameters */
                ) = _getPortfolioAndNTokenAssetValue(factors, nTokenBalance, blockTime);
                netLocalAssetValue = netLocalAssetValue
                    .add(netPortfolioAssetValue)
                    .add(nTokenHaircutAssetValue);
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                // NOTE: we must set the proper assetRate when we updateNetETHValue
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
        AccountContext memory accountContext,
        uint256 blockTime
    ) internal view returns (IU, IA[] memory) {
        FreeCollateralFactors memory factors;
        uint256 netLocalIndex;
        IA[] memory netLocalAssetValues = new IA[](10);

        if (accountContext.isBitmapEnabled()) {
            factors.cashGroup = CashGroup.buildCashGroupView(accountContext.bitmapCurrencyId);

            // prettier-ignore
            (
                IA netCashBalance,
                IA nTokenHaircutAssetValue,
                /* nTokenParameters */
            ) = _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            IA portfolioAssetValue =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            netLocalAssetValues[netLocalIndex] = netCashBalance
                .add(nTokenHaircutAssetValue)
                .add(portfolioAssetValue);
            factors.assetRate = factors.cashGroup.assetRate;
            _updateNetETHValue(
                accountContext.bitmapCurrencyId,
                netLocalAssetValues[netLocalIndex],
                factors
            );

            netLocalIndex++;
        } else {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            bytes2 currencyBytes = bytes2(currencies);
            uint16 currencyId = uint16(currencyBytes & Constants.UNMASK_FLAGS);
            NT nTokenBalance;
            (netLocalAssetValues[netLocalIndex], nTokenBalance) = _getCurrencyBalances(
                account,
                currencyBytes
            );

            if (_isActiveInPortfolio(currencyBytes) || nTokenBalance.isPosNotZero()) {
                factors.cashGroup = CashGroup.buildCashGroupView(currencyId);
                // prettier-ignore
                (
                    IA netPortfolioValue,
                    IA nTokenHaircutAssetValue,
                    /* nTokenParameters */
                ) = _getPortfolioAndNTokenAssetValue(factors, nTokenBalance, blockTime);

                netLocalAssetValues[netLocalIndex] = netLocalAssetValues[netLocalIndex]
                    .add(netPortfolioValue)
                    .add(nTokenHaircutAssetValue);
                factors.assetRate = factors.cashGroup.assetRate;
            } else {
                factors.assetRate = AssetRate.buildAssetRateView(currencyId);
            }

            _updateNetETHValue(currencyId, netLocalAssetValues[netLocalIndex], factors);
            netLocalIndex++;
            currencies = currencies << 16;
        }

        return (factors.netETHValue, netLocalAssetValues);
    }

    /// @notice Calculates the net value of a currency within a portfolio, this is a bit
    /// convoluted to fit into the stack frame
    function _calculateLiquidationAssetValue(
        FreeCollateralFactors memory factors,
        LiquidationFactors memory liquidationFactors,
        bytes2 currencyBytes,
        bool setLiquidationFactors,
        uint256 blockTime
    ) private returns (IA) {
        uint16 currencyId = uint16(currencyBytes & Constants.UNMASK_FLAGS);
        (IA netLocalAssetValue, NT nTokenBalance) =
            _getCurrencyBalances(liquidationFactors.account, currencyBytes);

        if (_isActiveInPortfolio(currencyBytes) || nTokenBalance.isPosNotZero()) {
            factors.cashGroup = CashGroup.buildCashGroupStateful(currencyId);
            (IA netPortfolioValue, IA nTokenHaircutAssetValue, bytes6 nTokenParameters) =
                _getPortfolioAndNTokenAssetValue(factors, nTokenBalance, blockTime);

            netLocalAssetValue = netLocalAssetValue
                .add(netPortfolioValue)
                .add(nTokenHaircutAssetValue);
            factors.assetRate = factors.cashGroup.assetRate;

            // If collateralCurrencyId is set to zero then this is a local currency liquidation
            if (setLiquidationFactors) {
                liquidationFactors.collateralCashGroup = factors.cashGroup;
                liquidationFactors.nTokenParameters = nTokenParameters;
                liquidationFactors.nTokenHaircutAssetValue = nTokenHaircutAssetValue;
            }
        } else {
            factors.assetRate = AssetRate.buildAssetRateStateful(currencyId);
        }

        return netLocalAssetValue;
    }

    /// @notice A version of getFreeCollateral used during liquidation to save off necessary additional information.
    function getLiquidationFactors(
        address account,
        AccountContext memory accountContext,
        uint256 blockTime,
        uint256 localCurrencyId,
        uint256 collateralCurrencyId
    ) internal returns (LiquidationFactors memory, PortfolioAsset[] memory) {
        FreeCollateralFactors memory factors;
        LiquidationFactors memory liquidationFactors;
        // This is only set to reduce the stack size
        liquidationFactors.account = account;

        if (accountContext.isBitmapEnabled()) {
            factors.cashGroup = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
            (IA netCashBalance, IA nTokenHaircutAssetValue, bytes6 nTokenParameters) =
                _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            IA portfolioBalance =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            IA netLocalAssetValue =
                netCashBalance.add(nTokenHaircutAssetValue).add(portfolioBalance);
            factors.assetRate = factors.cashGroup.assetRate;
            ETHRate memory ethRate =
                _updateNetETHValue(accountContext.bitmapCurrencyId, netLocalAssetValue, factors);

            // If the bitmap currency id can only ever be the local currency where debt is held.
            // During enable bitmap we check that the account has no assets in their portfolio and
            // no cash debts.
            if (accountContext.bitmapCurrencyId == localCurrencyId) {
                liquidationFactors.localAssetAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;
                liquidationFactors.localAssetRate = factors.assetRate;

                // This will be the case during local currency or local fCash liquidation
                if (collateralCurrencyId == 0) {
                    // If this is local fCash liquidation, the cash group information is required
                    // to calculate fCash haircuts and buffers.
                    liquidationFactors.collateralCashGroup = factors.cashGroup;
                    liquidationFactors.nTokenHaircutAssetValue = nTokenHaircutAssetValue;
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
                uint256 tempId = uint256(uint16(currencyBytes & Constants.UNMASK_FLAGS));
                setLiquidationFactors =
                    (tempId == localCurrencyId && collateralCurrencyId == 0) ||
                    tempId == collateralCurrencyId;
            }
            IA netLocalAssetValue =
                _calculateLiquidationAssetValue(
                    factors,
                    liquidationFactors,
                    currencyBytes,
                    setLiquidationFactors,
                    blockTime
                );

            uint256 currencyId = uint256(uint16(currencyBytes & Constants.UNMASK_FLAGS));
            ETHRate memory ethRate = _updateNetETHValue(currencyId, netLocalAssetValue, factors);

            if (currencyId == collateralCurrencyId) {
                // Ensure that this is set even if the cash group is not loaded, it will not be
                // loaded if the account only has a cash balance and no nTokens or assets
                liquidationFactors.collateralCashGroup.assetRate = factors.assetRate;
                liquidationFactors.collateralAssetAvailable = netLocalAssetValue;
                liquidationFactors.collateralETHRate = ethRate;
            } else if (currencyId == localCurrencyId) {
                // This branch will not be entered if bitmap is enabled
                liquidationFactors.localAssetAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;
                liquidationFactors.localAssetRate = factors.assetRate;
                // If this is local fCash liquidation, the cash group information is required
                // to calculate fCash haircuts and buffers and it will have been set in
                // _calculateLiquidationAssetValue above because the account must have fCash assets,
                // there is no need to set cash group in this branch.
            }

            currencies = currencies << 16;
        }

        liquidationFactors.netETHValue = factors.netETHValue;
        require(liquidationFactors.netETHValue.isNegNotZero(), "Sufficient collateral");

        // Refetch the portfolio if it exists, AssetHandler.getNetCashValue updates values in memory to do fCash
        // netting which will make further calculations incorrect.
        if (accountContext.assetArrayLength > 0) {
            factors.portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }

        return (liquidationFactors, factors.portfolio);
    }
}
