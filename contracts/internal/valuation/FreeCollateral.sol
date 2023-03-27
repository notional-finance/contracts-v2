// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    CashGroupParameters,
    PortfolioAsset,
    ETHRate,
    AccountContext,
    nTokenPortfolio,
    MarketParameters,
    LiquidationFactors
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {Bitmap} from "../../math/Bitmap.sol";

import {CashGroup} from "../markets/CashGroup.sol";
import {AccountContextHandler} from "../AccountContextHandler.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {PortfolioHandler} from "../portfolio/PortfolioHandler.sol";
import {BitmapAssetsHandler} from "../portfolio/BitmapAssetsHandler.sol";
import {nTokenHandler} from "../nToken/nTokenHandler.sol";
import {nTokenCalculations} from "../nToken/nTokenCalculations.sol";

import {ExchangeRate} from "./ExchangeRate.sol";
import {AssetHandler} from "./AssetHandler.sol";

library FreeCollateral {
    using SafeInt256 for int256;
    using Bitmap for bytes;
    using ExchangeRate for ETHRate;
    using PrimeRateLib for PrimeRate;
    using AccountContextHandler for AccountContext;
    using nTokenHandler for nTokenPortfolio;

    /// @dev This is only used within the library to clean up the stack
    struct FreeCollateralFactors {
        int256 netETHValue;
        bool updateContext;
        uint256 portfolioIndex;
        CashGroupParameters cashGroup;
        PortfolioAsset[] portfolio;
        PrimeRate primeRate;
        nTokenPortfolio nToken;
    }

    /// @notice Checks if an asset is active in the portfolio
    function _isActiveInPortfolio(bytes2 currencyBytes) private pure returns (bool) {
        return currencyBytes & Constants.ACTIVE_IN_PORTFOLIO == Constants.ACTIVE_IN_PORTFOLIO;
    }

    /// @notice Checks if currency balances are active in the account returns them if true
    /// @return cash balance, nTokenBalance
    function _getCurrencyBalances(
        address account,
        bytes2 currencyBytes,
        PrimeRate memory primeRate
    ) private view returns (int256, int256) {
        if (currencyBytes & Constants.ACTIVE_IN_BALANCES == Constants.ACTIVE_IN_BALANCES) {
            uint16 currencyId = uint16(currencyBytes & Constants.UNMASK_FLAGS);
            // prettier-ignore
            (
                int256 cashBalance,
                int256 nTokenBalance,
                /* lastClaimTime */,
                /* accountIncentiveDebt */
            ) = BalanceHandler.getBalanceStorage(account, currencyId, primeRate);

            return (cashBalance, nTokenBalance);
        }

        return (0, 0);
    }

    /// @notice Calculates the nToken asset value with a haircut set by governance
    /// @return the value of the account's nTokens after haircut, the nToken parameters
    function _getNTokenHaircutPrimePV(
        CashGroupParameters memory cashGroup,
        nTokenPortfolio memory nToken,
        int256 tokenBalance,
        uint256 blockTime
    ) internal view returns (int256, bytes6) {
        nToken.loadNTokenPortfolioNoCashGroup(cashGroup.currencyId);
        nToken.cashGroup = cashGroup;

        int256 nTokenPrimePV = nTokenCalculations.getNTokenPrimePV(nToken, blockTime);

        // (tokenBalance * nTokenValue * haircut) / totalSupply
        int256 nTokenHaircutPrimePV =
            tokenBalance
                .mul(nTokenPrimePV)
                .mul(uint8(nToken.parameters[Constants.PV_HAIRCUT_PERCENTAGE]))
                .div(Constants.PERCENTAGE_DECIMALS)
                .div(nToken.totalSupply);

        // nToken.parameters is returned for use in liquidation
        return (nTokenHaircutPrimePV, nToken.parameters);
    }

    /// @notice Calculates portfolio and/or nToken values while using the supplied cash groups and
    /// markets. The reason these are grouped together is because they both require storage reads of the same
    /// values.
    function _getPortfolioAndNTokenAssetValue(
        FreeCollateralFactors memory factors,
        int256 nTokenBalance,
        uint256 blockTime
    )
        private
        view
        returns (
            int256 netPortfolioValue,
            int256 nTokenHaircutPrimeValue,
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
                blockTime,
                factors.portfolioIndex
            );
        } else {
            netPortfolioValue = 0;
        }

        if (nTokenBalance > 0) {
            (nTokenHaircutPrimeValue, nTokenParameters) = _getNTokenHaircutPrimePV(
                factors.cashGroup,
                factors.nToken,
                nTokenBalance,
                blockTime
            );
        } else {
            nTokenHaircutPrimeValue = 0;
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
            int256 cashBalance,
            int256 nTokenHaircutPrimeValue,
            bytes6 nTokenParameters
        )
    {
        int256 nTokenBalance;
        // prettier-ignore
        (
            cashBalance,
            nTokenBalance, 
            /* lastClaimTime */,
            /* accountIncentiveDebt */
        ) = BalanceHandler.getBalanceStorage(
            account,
            accountContext.bitmapCurrencyId,
            factors.cashGroup.primeRate
        );

        if (nTokenBalance > 0) {
            (nTokenHaircutPrimeValue, nTokenParameters) = _getNTokenHaircutPrimePV(
                factors.cashGroup,
                factors.nToken,
                nTokenBalance,
                blockTime
            );
        } else {
            nTokenHaircutPrimeValue = 0;
        }
    }

    /// @notice Returns portfolio value for the bitmapped currency
    function _getBitmapPortfolioValue(
        address account,
        uint256 blockTime,
        AccountContext memory accountContext,
        FreeCollateralFactors memory factors
    ) private view returns (int256) {
        (int256 netPortfolioValueUnderlying, bool bitmapHasDebt) =
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
        return factors.cashGroup.primeRate.convertFromUnderlying(netPortfolioValueUnderlying);
    }

    function _updateNetETHValue(
        uint256 currencyId,
        int256 netLocalAssetValue,
        FreeCollateralFactors memory factors
    ) private view returns (ETHRate memory) {
        ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
        // Converts to underlying first, ETH exchange rates are in underlying
        factors.netETHValue = factors.netETHValue.add(
            ethRate.convertToETH(factors.primeRate.convertToUnderlying(netLocalAssetValue))
        );

        return ethRate;
    }

    /// @notice Stateful version of get free collateral, returns the total net ETH value and true or false if the account
    /// context needs to be updated.
    function getFreeCollateralStateful(
        address account,
        AccountContext memory accountContext,
        uint256 blockTime
    ) internal returns (int256, bool) {
        FreeCollateralFactors memory factors;
        bool hasCashDebt;

        if (accountContext.isBitmapEnabled()) {
            factors.cashGroup = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);

            // prettier-ignore
            (
                int256 netCashBalance,
                int256 nTokenHaircutPrimeValue,
                /* nTokenParameters */
            ) = _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            if (netCashBalance < 0) hasCashDebt = true;

            int256 portfolioAssetValue =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);
            int256 netLocalAssetValue =
                netCashBalance.add(nTokenHaircutPrimeValue).add(portfolioAssetValue);

            factors.primeRate = factors.cashGroup.primeRate;
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
            // Explicitly ensures that bitmap currency cannot be double counted
            require(currencyId != accountContext.bitmapCurrencyId);

            factors.primeRate = PrimeRateLib.buildPrimeRateStateful(currencyId);
            
            (int256 netLocalAssetValue, int256 nTokenBalance) =
                _getCurrencyBalances(account, currencyBytes, factors.primeRate);
            if (netLocalAssetValue < 0) hasCashDebt = true;

            if (_isActiveInPortfolio(currencyBytes) || nTokenBalance > 0) {
                factors.cashGroup = CashGroup.buildCashGroupStateful(currencyId);

                // prettier-ignore
                (
                    int256 netPortfolioAssetValue,
                    int256 nTokenHaircutPrimeValue,
                    /* nTokenParameters */
                ) = _getPortfolioAndNTokenAssetValue(factors, nTokenBalance, blockTime);
                netLocalAssetValue = netLocalAssetValue
                    .add(netPortfolioAssetValue)
                    .add(nTokenHaircutPrimeValue);
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
    ) internal view returns (int256, int256[] memory) {
        FreeCollateralFactors memory factors;
        uint256 netLocalIndex;
        int256[] memory netLocalAssetValues = new int256[](10);

        if (accountContext.isBitmapEnabled()) {
            factors.cashGroup = CashGroup.buildCashGroupView(accountContext.bitmapCurrencyId);

            // prettier-ignore
            (
                int256 netCashBalance,
                int256 nTokenHaircutPrimeValue,
                /* nTokenParameters */
            ) = _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioAssetValue =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            netLocalAssetValues[netLocalIndex] = netCashBalance
                .add(nTokenHaircutPrimeValue)
                .add(portfolioAssetValue);
            factors.primeRate = factors.cashGroup.primeRate;
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
            // Explicitly ensures that bitmap currency cannot be double counted
            require(currencyId != accountContext.bitmapCurrencyId);
            int256 nTokenBalance;
            (factors.primeRate, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);

            (netLocalAssetValues[netLocalIndex], nTokenBalance) = _getCurrencyBalances(
                account,
                currencyBytes,
                factors.primeRate
            );

            if (_isActiveInPortfolio(currencyBytes) || nTokenBalance > 0) {
                factors.cashGroup = CashGroup.buildCashGroupView(currencyId);
                // prettier-ignore
                (
                    int256 netPortfolioValue,
                    int256 nTokenHaircutPrimeValue,
                    /* nTokenParameters */
                ) = _getPortfolioAndNTokenAssetValue(factors, nTokenBalance, blockTime);

                netLocalAssetValues[netLocalIndex] = netLocalAssetValues[netLocalIndex]
                    .add(netPortfolioValue)
                    .add(nTokenHaircutPrimeValue);
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
    ) private returns (int256) {
        uint16 currencyId = uint16(currencyBytes & Constants.UNMASK_FLAGS);
        factors.primeRate = PrimeRateLib.buildPrimeRateStateful(currencyId);
        (int256 netLocalAssetValue, int256 nTokenBalance) =
            _getCurrencyBalances(liquidationFactors.account, currencyBytes, factors.primeRate);

        if (_isActiveInPortfolio(currencyBytes) || nTokenBalance > 0) {
            factors.cashGroup = CashGroup.buildCashGroupStateful(currencyId);
            (int256 netPortfolioValue, int256 nTokenHaircutPrimeValue, bytes6 nTokenParameters) =
                _getPortfolioAndNTokenAssetValue(factors, nTokenBalance, blockTime);

            netLocalAssetValue = netLocalAssetValue
                .add(netPortfolioValue)
                .add(nTokenHaircutPrimeValue);

            // If collateralCurrencyId is set to zero then this is a local currency liquidation
            if (setLiquidationFactors) {
                liquidationFactors.collateralCashGroup = factors.cashGroup;
                liquidationFactors.nTokenParameters = nTokenParameters;
                liquidationFactors.nTokenHaircutPrimeValue = nTokenHaircutPrimeValue;
            }
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
            (int256 netCashBalance, int256 nTokenHaircutPrimeValue, bytes6 nTokenParameters) =
                _getBitmapBalanceValue(account, blockTime, accountContext, factors);
            int256 portfolioBalance =
                _getBitmapPortfolioValue(account, blockTime, accountContext, factors);

            int256 netLocalAssetValue =
                netCashBalance.add(nTokenHaircutPrimeValue).add(portfolioBalance);
            factors.primeRate = factors.cashGroup.primeRate;
            ETHRate memory ethRate =
                _updateNetETHValue(accountContext.bitmapCurrencyId, netLocalAssetValue, factors);

            // If the bitmap currency id can only ever be the local currency where debt is held.
            // During enable bitmap we check that the account has no assets in their portfolio and
            // no cash debts.
            if (accountContext.bitmapCurrencyId == localCurrencyId) {
                liquidationFactors.localPrimeAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;
                liquidationFactors.localPrimeRate = factors.primeRate;

                // This will be the case during local currency or local fCash liquidation
                if (collateralCurrencyId == 0) {
                    // If this is local fCash liquidation, the cash group information is required
                    // to calculate fCash haircuts and buffers.
                    liquidationFactors.collateralCashGroup = factors.cashGroup;
                    liquidationFactors.nTokenHaircutPrimeValue = nTokenHaircutPrimeValue;
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
                // Explicitly ensures that bitmap currency cannot be double counted
                require(tempId != accountContext.bitmapCurrencyId);
                setLiquidationFactors =
                    (tempId == localCurrencyId && collateralCurrencyId == 0) ||
                    tempId == collateralCurrencyId;
            }
            int256 netLocalAssetValue =
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
                liquidationFactors.collateralCashGroup.primeRate = factors.primeRate;
                liquidationFactors.collateralAssetAvailable = netLocalAssetValue;
                liquidationFactors.collateralETHRate = ethRate;
            } else if (currencyId == localCurrencyId) {
                // This branch will not be entered if bitmap is enabled
                liquidationFactors.localPrimeAvailable = netLocalAssetValue;
                liquidationFactors.localETHRate = ethRate;
                liquidationFactors.localPrimeRate = factors.primeRate;
                // If this is local fCash liquidation, the cash group information is required
                // to calculate fCash haircuts and buffers and it will have been set in
                // _calculateLiquidationAssetValue above because the account must have fCash assets,
                // there is no need to set cash group in this branch.
            }

            currencies = currencies << 16;
        }

        liquidationFactors.netETHValue = factors.netETHValue;
        require(liquidationFactors.netETHValue < 0, "Sufficient collateral");

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
