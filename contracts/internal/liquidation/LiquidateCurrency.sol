// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./LiquidationHelpers.sol";
import "../AccountContextHandler.sol";
import "../valuation/ExchangeRate.sol";
import "../markets/CashGroup.sol";
import "../markets/AssetRate.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "../balances/BalanceHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library LiquidateCurrency {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

    // @audit remove, duplciate code
    function _hasLiquidityTokens(PortfolioAsset[] memory portfolio, uint256 currencyId)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < portfolio.length; i++) {
            // @audit-ok
            if (
                portfolio[i].currencyId == currencyId &&
                AssetHandler.isLiquidityToken(portfolio[i].assetType) &&
                // This should not be possible (a deleted asset) in the portfolio
                // at this stage of liquidation but we do this check to be defensive.
                portfolio[i].storageState != AssetStorageState.Delete
            ) {
                return true;
            }
        }

        return false;
    }

    /// @notice Liquidates an account by converting their local currency collateral into cash and
    /// eliminates any haircut value incurred by liquidity tokens or nTokens. Requires no capital
    /// on the part of the liquidator, this is pure arbitrage. It's highly unlikely that an account will
    /// encounter this scenario but this method is here for completeness.
    function liquidateLocalCurrency(
        uint256 localCurrency,
        uint96 maxNTokenLiquidation,
        uint256 blockTime,
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        PortfolioState memory portfolio
    ) internal returns (int256) {
        require(factors.localAssetAvailable < 0, "No local debt");

        // Formula here uses the buffer since we know localAssetAvailable is negative.
        // convertToLocal(netFCShortfallInETH) = localRequired * buffer
        // convertToLocal(netFCShortfallInETH) / buffer = localRequired
        int256 assetBenefitRequired =
            factors.cashGroup.assetRate.convertFromUnderlying(
                factors
                    .localETHRate
                    .convertETHTo(factors.netETHValue.neg())
                    .mul(Constants.PERCENTAGE_DECIMALS)
                    .div(factors.localETHRate.buffer)
            );

        int256 netAssetCashFromLiquidator;

        // @audit consider removing, redundant check
        if (_hasLiquidityTokens(portfolio.storedAssets, localCurrency)) {
            // @audit-ok
            WithdrawFactors memory w;
            (w, assetBenefitRequired) = _withdrawLocalLiquidityTokens(
                portfolio,
                factors,
                blockTime,
                assetBenefitRequired
            );
            // The liquidator will be paid this amount of incentive, it is deducted from what they
            // owe the liquidated account.
            netAssetCashFromLiquidator = w.totalIncentivePaid.neg();
            // The liquidity tokens have been withdrawn to cash.
            balanceState.netCashChange = w.totalCashClaim.sub(w.totalIncentivePaid);
        }

        // @audit-ok
        if (factors.nTokenHaircutAssetValue > 0) {
            int256 nTokensToLiquidate;
            {
                // This check is applied when saving parameters but we double check it here.
                require(
                    uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]) >
                    uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])
                ); // dev: haircut percentage underflow
                int256 haircutDiff =
                    int256(
                        uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]) -
                            uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])
                    // @audit convert to rate precision here instead
                    ) * Constants.PERCENTAGE_DECIMALS;

                // This will calculate how much nTokens to liquidate given the "assetBenefitRequired" calculated above.
                // We are supplied with the nTokenHaircutAssetValue, this is calculated in the formula below. This value
                // is calculated in FreeCollateral._getNTokenHaircutAssetPV and is equal to:
                // nTokenHaircutAssetValue = (tokenBalance * nTokenAssetPV * PV_HAIRCUT_PERCENTAGE) / totalSupply
                // where:
                //      nTokenAssetPV: this is the non-risk adjusted (no haircut applied) value of all nToken holdings
                //      totalSupply: the total supply of nTokens
                //      tokenBalance: the balance of the liquidated account's nTokens
                //      PV_HAIRCUT_PERCENTAGE: the discount to the nTokenAssetPV applied during risk adjustment
                //
                // Benefit gained is the local asset cash denominated amount of free collateral benefit given to the liquidated
                // account as a result of purchasing nTokens in exchange for cash in the same currency. The amount of benefit gained
                // is equal to the removal of the haircut on the nTokenValue minus the discount given to the liquidator.
                //
                // benefitGained = nTokensToLiquidate * (nTokenLiquidatedValue - nTokenHaircutAssetValue) / tokenBalance
                // where:
                //   nTokenHaircutAssetValue = (tokenBalance * nTokenAssetPV * PV_HAIRCUT_PERCENTAGE) / totalSupply
                //   nTokenLiquidatedValue = (tokenBalance * nTokenAssetPV * LIQUIDATION_HAIRCUT_PERCENTAGE) / totalSupply
                // NOTE: nTokenLiquidatedValue > nTokenHaircutAssetValue because we require that:
                //        LIQUIDATION_HAIRCUT_PERCENTAGE > PV_HAIRCUT_PERCENTAGE
                //
                // nTokenHaircutAssetValue - nTokenLiquidatedValue =
                //    (tokenBalance * nTokenAssetPV) / totalSupply * (LIQUIDATION_HAIRCUT_PERCENTAGE - PV_HAIRCUT_PERCENTAGE)
                //
                // From above:
                //    (tokenBalance * nTokenAssetPV) / totalSupply = nTokenHaircutAssetValue / PV_HAIRCUT_PERCENTAGE
                //
                // Therefore:
                // nTokenHaircutAssetValue - nTokenLiquidatedValue =
                //    nTokenHaircutAssetValue * (LIQUIDATION_HAIRCUT_PERCENTAGE - PV_HAIRCUT_PERCENTAGE) / PV_HAIRCUT_PERCENTAGE
                //
                // Finally:
                // benefitGained = nTokensToLiquidate * (nTokenLiquidatedValue - nTokenHaircutAssetValue) / tokenBalance
                // @audit-ok double checking units: cToken = nToken * (cToken - cToken) / nToken
                // nTokensToLiquidate = tokenBalance * benefitGained * PV_HAIRCUT / 
                //          (nTokenHaircutAssetValue * (LIQUIDATION_HAIRCUT - PV_HAIRCUT_PERCENTAGE))
                //
                // @audit-ok
                nTokensToLiquidate = assetBenefitRequired
                    .mul(balanceState.storedNTokenBalance)
                    .mul(int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])))
                    .div(factors.nTokenHaircutAssetValue.mul(haircutDiff));
            }

            // @audit-ok
            nTokensToLiquidate = LiquidationHelpers.calculateLiquidationAmount(
                nTokensToLiquidate,
                balanceState.storedNTokenBalance,
                maxNTokenLiquidation
            );
            balanceState.netNTokenTransfer = nTokensToLiquidate.neg();

            {
                // Calculates how much the liquidator must pay for the nTokens they are liquidating. Defined as:
                // nTokenHaircutAssetValue = (tokenBalance * nTokenAssetPV * PV_HAIRCUT_PERCENTAGE) / totalSupply
                // nTokenLiquidationPrice = (tokensToLiquidate * nTokenAssetPV * LIQUIDATION_HAIRCUT) / totalSupply
                //
                // Combining the two formulas:
                // nTokenHaircutAssetValue / (tokenBalance * PV_HAIRCUT_PERCENTAGE) = (nTokenAssetPV / totalSupply)
                // nTokenLiquidationPrice = (tokensToLiquidate * LIQUIDATION_HAIRCUT * nTokenHaircutAssetValue) / 
                //      (tokenBalance * PV_HAIRCUT_PERCENTAGE)
                // @audit-ok double check cToken = (nToken * % * cToken) / (nToken * %)
                // prettier-ignore
                int256 localAssetCash =
                    nTokensToLiquidate
                        .mul(int256(uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE])))
                        .mul(factors.nTokenHaircutAssetValue)
                        .div(int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])))
                        .div(balanceState.storedNTokenBalance);

                // @audit-ok
                balanceState.netCashChange = balanceState.netCashChange.add(localAssetCash);
                netAssetCashFromLiquidator = netAssetCashFromLiquidator.add(localAssetCash);
            }
        }

        return netAssetCashFromLiquidator;
    }

    /// @notice Liquidates collateral in the form of cash, liquidity token cash claims, or nTokens in that
    /// liquidation preference.
    function liquidateCollateralCurrency(
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        uint256 blockTime,
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        PortfolioState memory portfolio
    ) internal returns (int256) {
        require(factors.localAssetAvailable < 0, "No local debt");
        require(factors.collateralAssetAvailable > 0, "No collateral");

        (
            int256 requiredCollateralAssetCash,
            int256 localAssetCashFromLiquidator,
            int256 liquidationDiscount
        ) = _calculateCollateralToRaise(factors, maxCollateralLiquidation);

        int256 collateralAssetRemaining = requiredCollateralAssetCash;
        // @audit-ok
        // First in liquidation preference is the cash balance. Take as much cash as allowed.
        if (balanceState.storedCashBalance > 0) {
            if (balanceState.storedCashBalance >= collateralAssetRemaining) {
                balanceState.netCashChange = collateralAssetRemaining.neg();
                collateralAssetRemaining = 0;
            } else {
                // Sell off all cash balance and calculate remaining collateral
                // @audit-ok we have ensured that stored cash balance is positive
                balanceState.netCashChange = balanceState.storedCashBalance.neg();
                // @audit-ok collateral asset remaining cannot be negative
                collateralAssetRemaining = collateralAssetRemaining.subNoNeg(
                    balanceState.storedCashBalance
                );
            }
        }

        if (
            collateralAssetRemaining > 0 &&
            _hasLiquidityTokens(portfolio.storedAssets, balanceState.currencyId)
        ) {
            int256 newCollateralAssetRemaining =
                _withdrawCollateralLiquidityTokens(
                    portfolio,
                    factors,
                    blockTime,
                    collateralAssetRemaining
                );

            // This is a hack and ugly but there are stack issues in `LiquidateCurrencyAction.liquidateCollateralCurrency`
            // and this is a way to deal with it with the fewest contortions. There are no asset cash transfers within liquidation
            // so we overload the meaning of the field here to hold the net liquidity token cash change. Will zero this out before
            // going into finalize for the liquidated account's cash balances. This value is not simply added to the netCashChange field
            // because the cashClaim value is not stored in the balances and therefore the liquidated account will have too much cash
            // debited from their stored cash value.
            // @audit-ok
            balanceState.netAssetTransferInternalPrecision = collateralAssetRemaining.sub(
                newCollateralAssetRemaining
            );
            collateralAssetRemaining = newCollateralAssetRemaining;
        }

        if (collateralAssetRemaining > 0 && factors.nTokenHaircutAssetValue > 0) {
            // @audit-ok
            collateralAssetRemaining = _calculateCollateralNTokenTransfer(
                balanceState,
                factors,
                collateralAssetRemaining,
                maxNTokenLiquidation
            );
        }

        if (collateralAssetRemaining > 0) {
            // If there is any collateral asset remaining then recalculate the localAssetCashFromLiquidator, the
            // last two parameters are the same because they are denominated in asset cash values which are always
            // present value.
            int256 actualCollateralAssetSold = requiredCollateralAssetCash.sub(collateralAssetRemaining);
            // @audit-ok
            // prettier-ignore
            (
                /* collateralToRaise */,
                localAssetCashFromLiquidator
            ) = LiquidationHelpers.calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                actualCollateralAssetSold,
                actualCollateralAssetSold
            );
        }

        return localAssetCashFromLiquidator;
    }

    /// @dev Calculates anticipated collateral to raise, enforcing some limits. Actual transfers may be lower due
    /// to limits on the nToken transfer
    function _calculateCollateralToRaise(
        LiquidationFactors memory factors,
        int256 maxCollateralLiquidation
    )
        private
        pure
        returns (
            int256 requiredCollateralAssetCash,
            int256 localAssetCashFromLiquidator,
            int256 liquidationDiscount
        )
    {
        int256 assetCashBenefitRequired;
        // @audit-ok
        (assetCashBenefitRequired, liquidationDiscount) = LiquidationHelpers
            .calculateCrossCurrencyBenefitAndDiscount(factors);
        {
            // @audit-ok ETH = DAI * % * ETH/DAI - ETH * %
            // collateralCurrencyBenefit = localPurchased * localBuffer * exchangeRate -
            //      collateralToSell * collateralHaircut
            // @audit-ok ETH / ( ETH/DAI * % ) = DAI
            // localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)
            //
            // collateralCurrencyBenefit = [collateralToSell / (exchangeRate * liquidationDiscount)] * localBuffer * exchangeRate -
            //      collateralToSell * collateralHaircut
            // collateralCurrencyBenefit = (collateralToSell * localBuffer) / liquidationDiscount - collateralToSell * collateralHaircut
            // collateralCurrencyBenefit = collateralToSell * ((localBuffer / liquidationDiscount) - collateralHaircut)
            // collateralToSell = collateralCurrencyBenefit / ((localBuffer / liquidationDiscount) - collateralHaircut)
            // @audit-ok ETH = ETH / (% / % - %)
            // @audit-ok
            int256 denominator =
                factors
                    .localETHRate
                    .buffer
                    .mul(Constants.PERCENTAGE_DECIMALS)
                    .div(liquidationDiscount)
                    .sub(factors.collateralETHRate.haircut);

            // @audit-ok
            requiredCollateralAssetCash = assetCashBenefitRequired
                .mul(Constants.PERCENTAGE_DECIMALS)
                .div(denominator);
        }

        requiredCollateralAssetCash = LiquidationHelpers.calculateLiquidationAmount(
            requiredCollateralAssetCash,
            factors.collateralAssetAvailable,
            0 // will check userSpecifiedAmount below
        );

        // Enforce the user specified max liquidation amount
        // @audit why is this here?
        if (
            maxCollateralLiquidation > 0 && requiredCollateralAssetCash > maxCollateralLiquidation
        ) {
            requiredCollateralAssetCash = maxCollateralLiquidation;
        }

        // In this case the collateral asset present value and the collateral asset balance to sell are the same
        // value since cash is always equal to present value. That is why the last two parameters in calculateLocalToPurchase
        // are the same value.
        // @audit-ok
        // prettier-ignore
        (requiredCollateralAssetCash, localAssetCashFromLiquidator) = LiquidationHelpers
            .calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                requiredCollateralAssetCash,
                requiredCollateralAssetCash
            );

        return (requiredCollateralAssetCash, localAssetCashFromLiquidator, liquidationDiscount);
    }

    /// @dev Calculates the nToken transfer.
    function _calculateCollateralNTokenTransfer(
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        int256 collateralAssetRemaining,
        int256 maxNTokenLiquidation
    ) internal pure returns (int256) {
        // See longer comment in `liquidateLocalCurrency`, the main difference here is that we know how much
        // collateral we want to raise instead of calculating a "benefitGained" difference in a single currency.
        // collateralToRaise = (tokensToLiquidate * nTokenAssetPV * LIQUIDATION_HAIRCUT) / totalSupply
        // @audit cDAI = nDAI * cDAI * % / nDAI
        // where:
        //    nTokenHaircutAssetValue = (tokenBalance * nTokenAssetPV * PV_HAIRCUT_PERCENTAGE) / totalSupply
        //    nTokenAssetPV = (nTokenHaircutAssetValue * totalSupply) / (PV_HAIRCUT_PERCENTAGE * tokenBalance)

        // tokensToLiquidate = (collateralToRaise * totalSupply) / (nTokenAssetPV * LIQUIDATION_HAIRCUT)
        // tokensToLiquidate = (collateralToRaise * tokenBalance * PV_HAIRCUT) /
        //      (nTokenHaircutAssetValue * LIQUIDATION_HAIRCUT)

        int256 nTokenLiquidationHaircut =
            uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]);
        int256 nTokenHaircut =
            uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]);
        // @audit-ok
        int256 nTokensToLiquidate =
            collateralAssetRemaining
                .mul(balanceState.storedNTokenBalance)
                .mul(nTokenHaircut)
                .div(factors.nTokenHaircutAssetValue.mul(nTokenLiquidationHaircut));

        // @audit-ok
        if (maxNTokenLiquidation > 0 && nTokensToLiquidate > maxNTokenLiquidation) {
            nTokensToLiquidate = maxNTokenLiquidation;
        }

        // @audit-ok
        if (nTokensToLiquidate > balanceState.storedNTokenBalance) {
            nTokensToLiquidate = balanceState.storedNTokenBalance;
        }

        balanceState.netNTokenTransfer = nTokensToLiquidate.neg();
        // NOTE: it's possible that this results in > DEFAULT_LIQUIDATION_PORTION in PV terms. However, it will not be more than
        // the liquidateHaircutPercentage which will be set to a nominal amount. Since DEFAULT_LIQUIDATION_PORTION is arbitrary we
        // don't put too much emphasis on this and allow it to occur.
        // Formula here:
        // collateralToRaise = (tokensToLiquidate * nTokenHaircutAssetValue * LIQUIDATION_HAIRCUT) / (PV_HAIRCUT_PERCENTAGE * tokenBalance)
        // @audit-ok
        collateralAssetRemaining = collateralAssetRemaining.subNoNeg(
            nTokensToLiquidate
                .mul(factors.nTokenHaircutAssetValue)
                .mul(nTokenLiquidationHaircut)
                .div(nTokenHaircut)
                .div(balanceState.storedNTokenBalance)
        );

        return collateralAssetRemaining;
    }

    struct WithdrawFactors {
        int256 netCashIncrease;
        int256 fCash;
        int256 assetCash;
        int256 totalIncentivePaid;
        int256 totalCashClaim;
        int256 incentivePaid;
    }

    /// @notice Withdraws local liquidity tokens from a portfolio and pays an incentive to the liquidator.
    /// @return withdraw factors to update liquidator and liquidated cash balances, the asset amount remaining
    function _withdrawLocalLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint256 blockTime,
        int256 assetAmountRemaining
    ) internal returns (WithdrawFactors memory, int256) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        MarketParameters memory market;
        // Do this to deal with stack issues
        WithdrawFactors memory w;

        for (uint256 i = 0; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            // @audit-ok
            if (!_isValidWithdrawToken(asset, factors.cashGroup.currencyId)) continue;

            (w.assetCash, w.fCash) = _loadMarketAndGetClaims(
                asset,
                factors.cashGroup,
                market,
                blockTime
            );

            (w.netCashIncrease, w.incentivePaid) = _calculateNetCashIncreaseAndIncentivePaid(
                factors, w.assetCash, asset.assetType);

            // (netCashToAccount <= assetAmountRemaining)
            if (w.netCashIncrease.subNoNeg(w.incentivePaid) <= assetAmountRemaining) {
                // @audit-ok
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // assetAmountRemaining = assetAmountRemaining - netCashToAccount
                // netCashToAccount = netCashIncrease - incentivePaid
                // overflow checked above
                assetAmountRemaining = assetAmountRemaining - w.netCashIncrease.sub(w.incentivePaid);
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // @audit-ok
                int256 tokensToRemove = asset.notional
                    .mul(assetAmountRemaining)
                    .div(w.netCashIncrease.subNoNeg(w.incentivePaid));

                (w.assetCash, w.fCash) = market.removeLiquidity(tokensToRemove);
                // Recalculate net cash increase and incentive paid. w.assetCash is different because we partially
                // remove asset cash
                (w.netCashIncrease, w.incentivePaid) = _calculateNetCashIncreaseAndIncentivePaid(
                    factors, w.assetCash, asset.assetType);

                // Remove liquidity token balance
                asset.notional = asset.notional.subNoNeg(tokensToRemove);
                asset.storageState = AssetStorageState.Update;
                assetAmountRemaining = 0;
            }

            w.totalIncentivePaid = w.totalIncentivePaid.add(w.incentivePaid);
            w.totalCashClaim = w.totalCashClaim.add(w.assetCash);

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            // @audit-ok
            portfolioState.addAsset(
                factors.cashGroup.currencyId,
                asset.maturity,
                Constants.FCASH_ASSET_TYPE,
                w.fCash
            );

            if (assetAmountRemaining == 0) break;
        }

        return (w, assetAmountRemaining);
    }

    function _calculateNetCashIncreaseAndIncentivePaid(
        LiquidationFactors memory factors,
        int256 assetCash,
        uint256 assetType
    ) private pure returns (int256 netCashIncrease, int256 incentivePaid) {
        // @audit-ok
        // We can only recollateralize the local currency using the part of the liquidity token that
        // between the pre-haircut cash claim and the post-haircut cash claim. Part of the cash raised
        // is paid out as an incentive so that must be accounted for.
        // netCashIncrease = cashClaim * (1 - haircut)
        // netCashIncrease = netCashToAccount + incentivePaid
        // incentivePaid = netCashIncrease * incentivePercentage
        int256 haircut = factors.cashGroup.getLiquidityHaircut(assetType);
        netCashIncrease = assetCash.mul(Constants.PERCENTAGE_DECIMALS.sub(haircut)).div(
            Constants.PERCENTAGE_DECIMALS
        );
        incentivePaid = netCashIncrease.mul(Constants.TOKEN_REPO_INCENTIVE_PERCENT).div(
            Constants.PERCENTAGE_DECIMALS
        );
    }

    /// @dev Similar to withdraw liquidity tokens, except there is no incentive paid and we do not worry about
    /// haircut amounts, we simply withdraw as much collateral as needed.
    /// @return the new collateral amount required in the liquidation
    function _withdrawCollateralLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint256 blockTime,
        int256 collateralToWithdraw
    ) internal returns (int256) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        MarketParameters memory market;

        for (uint256 i = 0; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (!_isValidWithdrawToken(asset, factors.cashGroup.currencyId)) continue;

            (int256 cashClaim, int256 fCashClaim) = _loadMarketAndGetClaims(
                asset,
                factors.cashGroup,
                market,
                blockTime
            );

            if (cashClaim <= collateralToWithdraw) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                // @audit this should set it directly
                market.removeLiquidity(asset.notional);

                // overflow checked above
                collateralToWithdraw = collateralToWithdraw - cashClaim;
            } else {
                // @audit-ok
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // NOTE: dust can accrue when withdrawing liquidity at this point
                int256 tokensToRemove = asset.notional.mul(collateralToWithdraw).div(cashClaim);
                (cashClaim, fCashClaim) = market.removeLiquidity(tokensToRemove);

                // Remove liquidity token balance
                asset.notional = asset.notional.subNoNeg(tokensToRemove);
                asset.storageState = AssetStorageState.Update;
                collateralToWithdraw = 0;
            }

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                factors.cashGroup.currencyId,
                asset.maturity,
                Constants.FCASH_ASSET_TYPE,
                fCashClaim
            );

            if (collateralToWithdraw == 0) return 0;
        }

        return collateralToWithdraw;
    }

    function _isValidWithdrawToken(PortfolioAsset memory asset, uint256 currencyId) private pure returns (bool) {
        return (
            asset.currencyId == currencyId &&
            AssetHandler.isLiquidityToken(asset.assetType) &&
            // This should not be possible (a deleted asset) in the portfolio
            // at this stage of liquidation but we do this check to be defensive.
            asset.storageState != AssetStorageState.Delete
        );
    }

    function _loadMarketAndGetClaims(
        PortfolioAsset memory asset,
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        uint256 blockTime
    ) private view returns (int256 cashClaim, int256 fCashClaim) {
        uint256 marketIndex = asset.assetType - 1;
        cashGroup.loadMarket(market, marketIndex, true, blockTime);
        (cashClaim, fCashClaim) = asset.getCashClaims(market);
    }

    function finalizeLiquidatedCollateralAndPortfolio(
        address liquidateAccount,
        BalanceState memory collateralBalanceState,
        AccountContext memory accountContext,
        PortfolioState memory portfolio
    ) internal {
        // Asset transfer value is set to record liquidity token withdraw balances and should not be
        // finalized inside the liquidated collateral. See comment inside liquidateCollateralCurrency
        // for more details
        int256 tmpAssetTransferAmount = collateralBalanceState.netAssetTransferInternalPrecision;
        collateralBalanceState.netAssetTransferInternalPrecision = 0;

        // Finalize liquidated account balance
        // @audit-ok set balances before portfolio
        collateralBalanceState.finalize(liquidateAccount, accountContext, false);
        if (!accountContext.isBitmapEnabled()) {
            // Portfolio updates only happen if the account has liquidity tokens, which can only be the
            // case in a non-bitmapped portfolio.
            // @audit-ok
            accountContext.storeAssetsAndUpdateContext(
                liquidateAccount,
                portfolio,
                true // is liquidation
            );
        }
        // @audit-ok
        accountContext.setAccountContext(liquidateAccount);

        collateralBalanceState.netAssetTransferInternalPrecision = tmpAssetTransferAmount;
    }
}
