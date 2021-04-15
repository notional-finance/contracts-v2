// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AccountContextHandler.sol";
import "./valuation/AssetHandler.sol";
import "./valuation/ExchangeRate.sol";
import "./markets/CashGroup.sol";
import "./portfolio/BitmapAssetsHandler.sol";
import "./portfolio/PortfolioHandler.sol";
import "./balances/BalanceHandler.sol";
import "../external/FreeCollateralExternal.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Liquidation {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using AccountContextHandler for AccountContext;
    using Market for MarketParameters;

    /// @notice Settles accounts and returns liquidation factors for all of the liquidation actions.
    function preLiquidationActions(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency
    )
        internal
        returns (
            AccountContext memory,
            LiquidationFactors memory,
            PortfolioState memory
        )
    {
        require(localCurrency != 0);
        // Collateral currency must be unset or not equal to the local currency
        require(collateralCurrency == 0 || collateralCurrency != localCurrency);
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioAsset[] memory portfolio
        ) =
            FreeCollateralExternal.getLiquidationFactors(
                liquidateAccount,
                localCurrency,
                collateralCurrency
            );

        PortfolioState memory portfolioState =
            PortfolioState({
                storedAssets: portfolio,
                newAssets: new PortfolioAsset[](0),
                lastNewAssetIndex: 0,
                storedAssetLength: portfolio.length
            });

        return (accountContext, factors, portfolioState);
    }

    /// @notice We allow liquidators to purchase up to Constants.MAX_LIQUIDATION_PORTION percentage of collateral
    /// assets during liquidation to recollateralize an account as long as it does not also put the account
    /// further into negative free collateral (i.e. constraints on local available and collateral available).
    /// Additionally, we allow the liquidator to specify a maximum amount of collateral they would like to
    /// purchase so we also enforce that limit here.
    function _calculateMaxLiquidationAmount(
        int256 initialAmountToLiquidate,
        int256 maxTotalBalance,
        int256 userSpecifiedMaximum
    ) private pure returns (int256) {
        int256 maxAllowedAmount =
            maxTotalBalance.mul(Constants.MAX_LIQUIDATION_PORTION).div(
                Constants.PERCENTAGE_DECIMALS
            );

        int256 result = initialAmountToLiquidate;

        if (initialAmountToLiquidate > maxTotalBalance) {
            result = maxTotalBalance;
        }

        if (initialAmountToLiquidate < maxAllowedAmount) {
            // Allow the liquidator to go up to the max allowed amount
            result = maxAllowedAmount;
        }

        if (userSpecifiedMaximum > 0 && result > userSpecifiedMaximum) {
            // Do not allow liquidation above the user specified maximum
            result = userSpecifiedMaximum;
        }

        return result;
    }

    /// @dev Calculates factors when liquidating across two currencies
    function _calculateCrossCurrencyBenefitAndDiscount(LiquidationFactors memory factors)
        private
        pure
        returns (int256, int256)
    {
        int256 liquidationDiscount;
        // This calculation returns the amount of benefit that selling collateral for local currency will
        // be back to the account.
        int256 benefitRequired =
            factors
                .collateralETHRate
                .convertETHTo(factors.netETHValue.neg())
                .mul(Constants.PERCENTAGE_DECIMALS)
            // If the haircut is zero here the transaction will revert, which is the correct result. Liquidating
            // collateral with a zero haircut will have no net benefit back to the liquidated account.
                .div(factors.collateralETHRate.haircut);

        if (
            factors.collateralETHRate.liquidationDiscount > factors.localETHRate.liquidationDiscount
        ) {
            liquidationDiscount = factors.collateralETHRate.liquidationDiscount;
        } else {
            liquidationDiscount = factors.localETHRate.liquidationDiscount;
        }

        return (benefitRequired, liquidationDiscount);
    }

    /// @notice Calculates the local to purchase in cross currency liquidations. Ensures that local to purchase
    /// is not so large that the account is put further into debt.
    function _calculateLocalToPurchase(
        LiquidationFactors memory factors,
        int256 liquidationDiscount,
        int256 collateralPresentValue,
        int256 collateralBalanceToSell
    ) private pure returns (int256, int256) {
        // Converts collateral present value to the local amount along with the liquidation discount.
        // localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)
        int256 localToPurchase =
            collateralPresentValue
                .mul(Constants.PERCENTAGE_DECIMALS)
                .mul(factors.localETHRate.rateDecimals)
                .div(ExchangeRate.exchangeRate(factors.localETHRate, factors.collateralETHRate))
                .div(liquidationDiscount);

        if (localToPurchase > factors.localAvailable.neg()) {
            // If the local to purchase will put the local available into negative territory we
            // have to cut the collateral purchase amount back. Putting local available into negative
            // territory will force the liquidated account to incur more debt.
            collateralBalanceToSell = collateralBalanceToSell.mul(factors.localAvailable.neg()).div(
                localToPurchase
            );

            localToPurchase = factors.localAvailable.neg();
        }

        return (collateralBalanceToSell, localToPurchase);
    }

    /// @notice Calculates the two discount factors relevant when liquidating fCash.
    function _calculatefCashDiscounts(
        LiquidationFactors memory factors,
        uint256 maturity,
        uint256 blockTime
    ) private view returns (int256, int256) {
        uint256 oracleRate = factors.cashGroup.getOracleRate(factors.markets, maturity, blockTime);

        uint256 timeToMaturity = maturity.sub(blockTime);
        // This is the discount factor used to calculate the fCash present value during free collateral
        int256 riskAdjustedDiscountFactor =
            AssetHandler.getDiscountFactor(
                timeToMaturity,
                oracleRate.add(factors.cashGroup.getfCashHaircut())
            );
        // This is the discount factor that liquidators get to purchase fCash at, will be larger than
        // the risk adjusted discount factor.
        int256 liquidationDiscountFactor =
            AssetHandler.getDiscountFactor(
                timeToMaturity,
                oracleRate.add(factors.cashGroup.getLiquidationfCashHaircut())
            );

        return (riskAdjustedDiscountFactor, liquidationDiscountFactor);
    }

    function _hasLiquidityTokens(PortfolioAsset[] memory portfolio, uint256 currencyId)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < portfolio.length; i++) {
            if (
                portfolio[i].currencyId == currencyId &&
                AssetHandler.isLiquidityToken(portfolio[i].assetType)
            ) {
                return true;
            }
        }

        return false;
    }

    /// @dev Helper function because of two portfolio types
    function _getfCashNotional(
        address liquidateAccount,
        fCashContext memory context,
        uint256 currencyId,
        uint256 maturity
    ) private view returns (int256) {
        if (context.accountContext.bitmapCurrencyId == currencyId) {
            int256 notional =
                BitmapAssetsHandler.getifCashNotional(liquidateAccount, currencyId, maturity);
            require(notional > 0, "Invalid fCash asset");
        }

        PortfolioAsset[] memory portfolio = context.portfolio.storedAssets;
        for (uint256 i; i < portfolio.length; i++) {
            if (
                portfolio[i].currencyId == currencyId &&
                portfolio[i].assetType == Constants.FCASH_ASSET_TYPE &&
                portfolio[i].maturity == maturity
            ) {
                require(portfolio[i].notional > 0, "Invalid fCash asset");
                return portfolio[i].notional;
            }
        }

        // If asset is not found then we return zero instead of failing in the case that a previous
        // liquidation has already liquidated the specified fCash asset. This liquidation can continue
        // to the next specified fCash asset.
        return 0;
    }

    /// @notice Liquidates an account by converting their local currency collateral into cash and
    /// eliminates any haircut value incurred by liquidity tokens or perpetual tokens. Requires no capital
    /// on the part of the liquidator, this is pure arbitrage. It's highly unlikely that an account will
    /// encounter this scenario but this method is here for completeness.
    function liquidateLocalCurrency(
        uint256 localCurrency,
        uint96 maxNTokenLiquidation,
        uint256 blockTime,
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        PortfolioState memory portfolio
    ) internal view returns (int256) {
        int256 benefitRequired =
            factors
                .localETHRate
                .convertETHTo(factors.netETHValue.neg())
                .mul(Constants.PERCENTAGE_DECIMALS)
                .div(factors.localETHRate.buffer);
        int256 netLocalFromLiquidator;

        if (_hasLiquidityTokens(portfolio.storedAssets, localCurrency)) {
            WithdrawFactors memory w;
            (w, benefitRequired) = _withdrawLocalLiquidityTokens(
                portfolio,
                factors,
                blockTime,
                benefitRequired
            );
            netLocalFromLiquidator = w.totalIncentivePaid.neg();
            balanceState.netCashChange = w.totalCashClaim.sub(w.totalIncentivePaid);
        }

        if (factors.nTokenValue > 0) {
            int256 nTokensToLiquidate;
            {
                // This will not underflow, checked when saving parameters
                int256 haircutDiff =
                    (int256(
                        uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE])
                    ) - int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]))) *
                        Constants.PERCENTAGE_DECIMALS;

                // benefitGained = perpTokensToLiquidate * (liquidatedPV - freeCollateralPV)
                // benefitGained = perpTokensToLiquidate * perpTokenPV * (liquidationHaircut - pvHaircut)
                // perpTokensToLiquidate = benefitGained / (perpTokenPV * (liquidationHaircut - pvHaircut))
                nTokensToLiquidate = benefitRequired.mul(Constants.INTERNAL_TOKEN_PRECISION).div(
                    factors.nTokenValue.mul(haircutDiff).div(Constants.PERCENTAGE_DECIMALS)
                );
            }

            nTokensToLiquidate = _calculateMaxLiquidationAmount(
                nTokensToLiquidate,
                balanceState.storedNTokenBalance,
                int256(maxNTokenLiquidation)
            );
            balanceState.netNTokenTransfer = nTokensToLiquidate.neg();

            {
                // fullPerpTokenPV = haircutTokenPV / haircutPercentage
                // localFromLiquidator = tokensToLiquidate * fullPerpTokenPV * liquidationHaircut / totalBalance
                // prettier-ignore
                int256 localCashValue =
                    nTokensToLiquidate
                        .mul(int256(uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE])))
                        .mul(factors.nTokenValue)
                        .div(int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])))
                        .div(balanceState.storedNTokenBalance);

                balanceState.netCashChange = balanceState.netCashChange.add(localCashValue);
                netLocalFromLiquidator = netLocalFromLiquidator.add(localCashValue);
            }
        }

        return netLocalFromLiquidator;
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
    ) internal view returns (int256) {
        require(factors.localAvailable < 0, "No local debt");
        require(factors.collateralAvailable > 0, "No collateral");

        (int256 collateralToRaise, int256 localToPurchase, int256 liquidationDiscount) =
            _calculateCollateralToRaise(factors, int256(maxCollateralLiquidation));

        int256 collateralRemaining = collateralToRaise;
        if (balanceState.storedCashBalance > 0) {
            if (balanceState.storedCashBalance > collateralRemaining) {
                balanceState.netCashChange = collateralRemaining.neg();
                collateralRemaining = 0;
            } else {
                // Sell off all cash balance and calculate remaining collateral
                balanceState.netCashChange = balanceState.storedCashBalance.neg();
                collateralRemaining = collateralRemaining.sub(balanceState.storedCashBalance);
            }
        }

        if (
            collateralRemaining > 0 &&
            _hasLiquidityTokens(portfolio.storedAssets, balanceState.currencyId)
        ) {
            int256 postWithdrawCollateral =
                _withdrawCollateralLiquidityTokens(
                    portfolio,
                    factors,
                    blockTime,
                    collateralRemaining
                );
            balanceState.netCashChange = balanceState.netCashChange.add(
                collateralRemaining.sub(postWithdrawCollateral)
            );
            collateralRemaining = postWithdrawCollateral;
        }

        if (collateralRemaining > 0 && factors.nTokenValue > 0) {
            collateralRemaining = _calculateCollateralNTokenTransfer(
                balanceState,
                factors,
                collateralRemaining,
                int256(maxNTokenLiquidation)
            );
        }

        if (collateralRemaining > 0) {
            // prettier-ignore
            (
                /* collateralToRaise */,
                localToPurchase
            ) = _calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                collateralToRaise.sub(collateralRemaining),
                collateralToRaise.sub(collateralRemaining)
            );
        }

        return localToPurchase;
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
            int256,
            int256,
            int256
        )
    {
        (int256 benefitRequired, int256 liquidationDiscount) =
            _calculateCrossCurrencyBenefitAndDiscount(factors);
        int256 collateralToRaise;
        {
            // collateralCurrencyBenefit = localPurchased * localBuffer * exchangeRate -
            //      collateralToSell * collateralHaircut
            // localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)
            //
            // collateralCurrencyBenefit = [collateralToSell / (exchangeRate * liquidationDiscount)] * localBuffer * exchangeRate -
            //      collateralToSell * collateralHaircut
            // collateralCurrencyBenefit = (collateralToSell * localBuffer) / liquidationDiscount - collateralToSell * collateralHaircut
            // collateralCurrencyBenefit = collateralToSell * (localBuffer / liquidationDiscount - collateralHaircut)
            // collateralToSell = collateralCurrencyBeneift / [(localBuffer / liquidationDiscount - collateralHaircut)]
            int256 denominator =
                factors
                    .localETHRate
                    .buffer
                    .mul(Constants.PERCENTAGE_DECIMALS)
                    .div(liquidationDiscount)
                    .sub(factors.collateralETHRate.haircut);

            collateralToRaise = benefitRequired.mul(Constants.PERCENTAGE_DECIMALS).div(denominator);
        }

        collateralToRaise = _calculateMaxLiquidationAmount(
            collateralToRaise,
            factors.collateralAvailable,
            0 // will check userSpecifiedAmount below
        );

        int256 localToPurchase;
        (collateralToRaise, localToPurchase) = _calculateLocalToPurchase(
            factors,
            liquidationDiscount,
            collateralToRaise,
            collateralToRaise
        );

        // Enforce the user specified max liquidation amount
        if (maxCollateralLiquidation > 0 && collateralToRaise > maxCollateralLiquidation) {
            collateralToRaise = maxCollateralLiquidation;

            // prettier-ignore
            (
                /* collateralToRaise */,
                localToPurchase
            ) = _calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                collateralToRaise,
                collateralToRaise
            );
        }

        return (collateralToRaise, localToPurchase, liquidationDiscount);
    }

    /// @dev Calculates the nToken transfer.
    function _calculateCollateralNTokenTransfer(
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        int256 collateralRemaining,
        int256 maxNTokenLiquidation
    ) internal pure returns (int256) {
        // fullNTokenPV = haircutTokenPV / haircutPercentage
        // collateralToRaise = tokensToLiquidate * fullNTokenPV * liquidationHaircut / totalBalance
        // tokensToLiquidate = collateralToRaise * totalBalance / (fullNTokenPV * liquidationHaircut)
        int256 nTokenLiquidationHaircut =
            int256(uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]));
        int256 nTokenHaircut =
            int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]));
        int256 nTokensToLiquidate =
            collateralRemaining.mul(balanceState.storedNTokenBalance).mul(nTokenHaircut).div(
                factors.nTokenValue.mul(nTokenLiquidationHaircut)
            );

        if (maxNTokenLiquidation > 0 && nTokensToLiquidate > maxNTokenLiquidation) {
            nTokensToLiquidate = maxNTokenLiquidation;
        }

        if (nTokensToLiquidate > balanceState.storedNTokenBalance) {
            nTokensToLiquidate = balanceState.storedNTokenBalance;
        }

        balanceState.netNTokenTransfer = nTokensToLiquidate.neg();
        // NOTE: it's possible that this results in > MAX_LIQUIDATION_PORTION in PV terms. However, it will not be more than
        // the liquidateHaircutPercentage which will be set to a nominal amount. Since MAX_LIQUIDATION_PORTION is arbitrary we
        // don't put too much emphasis on this and allow it to occur.
        collateralRemaining = collateralRemaining.subNoNeg(
            // collateralToRaise = (nTokenToLiquidate * nTokenPV * liquidateHaircutPercentage) / nTokenBalance
            nTokensToLiquidate
                .mul(factors.nTokenValue)
                .mul(nTokenLiquidationHaircut)
                .div(nTokenHaircut)
                .div(balanceState.storedNTokenBalance)
        );

        return collateralRemaining;
    }

    struct fCashContext {
        AccountContext accountContext;
        LiquidationFactors factors;
        PortfolioState portfolio;
        int256 benefitRequired;
        int256 localToPurchase;
        int256 liquidationDiscount;
        int256[] fCashNotionalTransfers;
    }

    /// @notice Allows the liquidator to purchase fCash in the same currency that a debt is denominated in. Ut's
    /// also possible that there is no debt in the local currency, in that case the liquidated account will gain the
    /// benefit of the difference between the discounted fCash value and the cash
    function liquidatefCashLocal(
        address liquidateAccount,
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint256 blockTime
    ) internal view {
        if (c.factors.localAvailable > 0) {
            // If local available is positive then we can bring it down to zero
            c.benefitRequired = c
                .factors
                .localETHRate
                .convertETHTo(c.factors.netETHValue.neg())
                .mul(Constants.PERCENTAGE_DECIMALS)
                .div(c.factors.localETHRate.haircut);
        } else {
            // If local available is negative then we can bring it up to zero
            c.benefitRequired = c
                .factors
                .localAvailable
                .neg()
                .mul(Constants.PERCENTAGE_DECIMALS)
                .div(c.factors.localETHRate.buffer);
        }

        for (uint256 i; i < fCashMaturities.length; i++) {
            int256 notional =
                _getfCashNotional(liquidateAccount, c, localCurrency, fCashMaturities[i]);
            if (notional == 0) continue;

            // We know that liquidation discount > risk adjusted discount because they are required to
            // be this way when setting cash group variables.
            (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) =
                _calculatefCashDiscounts(c.factors, fCashMaturities[i], blockTime);

            // The benefit to the liquidated account is the difference between the liquidation discount factor
            // and the risk adjusted discount factor:
            // localCurrencyBenefit = fCash * (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            // fCash = localCurrencyBeneift / (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            c.fCashNotionalTransfers[i] = c.benefitRequired.mul(Constants.RATE_PRECISION).div(
                liquidationDiscountFactor.sub(riskAdjustedDiscountFactor)
            );

            c.fCashNotionalTransfers[i] = _calculateMaxLiquidationAmount(
                c.fCashNotionalTransfers[i],
                notional,
                int256(maxfCashLiquidateAmounts[i])
            );

            // Calculate the amount of local currency required from the liquidator
            c.localToPurchase = c.localToPurchase.add(
                c.fCashNotionalTransfers[i].mul(liquidationDiscountFactor).div(
                    Constants.RATE_PRECISION
                )
            );

            // Deduct the total benefit gained from liquidating this fCash position
            c.benefitRequired = c.benefitRequired.sub(
                c.fCashNotionalTransfers[i]
                    .mul(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor))
                    .div(Constants.RATE_PRECISION)
            );

            if (c.benefitRequired <= 0) break;
        }
    }

    function _calculateCrossCurrencyfCashToLiquidate(
        fCashContext memory c,
        uint256 maturity,
        uint256 blockTime,
        int256 maxfCashLiquidateAmount,
        int256 notional
    ) private view returns (int256) {
        (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) =
            _calculatefCashDiscounts(c.factors, maturity, blockTime);

        // collateralPurchased = fCashToLiquidate * fCashDiscountFactor
        // (see: _calculateCollateralToRaise)
        // collateralBenefit = collateralPurchased * (localBuffer / liquidationDiscount - collateralHaircut)
        // totalBenefit = fCashBenefit + collateralBenefit
        // totalBenefit = fCashToLiquidate * (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      fCashToLiquidate * liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut)
        // totalBenefit = fCashToLiquidate * [
        //      (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      (liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut))
        // ]
        // fCashToLiquidate = totalBenefit / [
        //      (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      (liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut))
        // ]
        int256 benefitMultiplier;
        {
            // prettier-ignore
            int256 termTwo = (
                    c.factors.localETHRate.buffer.mul(Constants.PERCENTAGE_DECIMALS).div(
                        c.liquidationDiscount
                    )
                ).sub(c.factors.collateralETHRate.haircut);
            termTwo = liquidationDiscountFactor.mul(termTwo).div(Constants.PERCENTAGE_DECIMALS);
            int256 termOne = liquidationDiscountFactor.sub(riskAdjustedDiscountFactor);
            benefitMultiplier = termOne.add(termTwo);
        }

        int256 fCashToLiquidate =
            c.benefitRequired.mul(Constants.RATE_PRECISION).div(benefitMultiplier);
        fCashToLiquidate = _calculateMaxLiquidationAmount(
            fCashToLiquidate,
            notional,
            maxfCashLiquidateAmount
        );

        // Ensures that local available does not go above zero and collateral available does not go below zero
        int256 localToPurchase;
        (fCashToLiquidate, localToPurchase) = _limitPurchaseByAvailableAmounts(
            c,
            liquidationDiscountFactor,
            riskAdjustedDiscountFactor,
            fCashToLiquidate
        );

        // inverse of initial fCashToLiquidate calculation above
        // totalBenefit = fCashToLiquidate * [
        //      (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      (liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut))
        // ]
        int256 benefitGained =
            fCashToLiquidate.mul(benefitMultiplier).div(Constants.RATE_PRECISION);

        c.benefitRequired = c.benefitRequired.sub(benefitGained);
        c.localToPurchase = c.localToPurchase.add(localToPurchase);

        return fCashToLiquidate;
    }

    /// @dev Limits the fCash purchase to ensure that collateral available and local available do not go below zero,
    /// in both those cases the liquidated account would incur debt
    function _limitPurchaseByAvailableAmounts(
        fCashContext memory c,
        int256 liquidationDiscountFactor,
        int256 riskAdjustedDiscountFactor,
        int256 fCashToLiquidate
    ) private pure returns (int256, int256) {
        // The collateral value of the fCash is discounted back to PV given the liquidation discount factor,
        // this is the discounted value that the liquidator will purchase it at.
        int256 fCashLiquidationPV =
            fCashToLiquidate.mul(liquidationDiscountFactor).div(Constants.RATE_PRECISION);
        int256 fCashBenefit =
            fCashToLiquidate.mul(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor)).div(
                Constants.RATE_PRECISION
            );

        // Ensures that collateralAvailable does not go below zero
        if (fCashLiquidationPV > c.factors.collateralAvailable.add(fCashBenefit)) {
            fCashToLiquidate = c.factors.collateralAvailable.mul(Constants.RATE_PRECISION).div(
                liquidationDiscountFactor
            );
        }

        int256 localToPurchase;
        (fCashToLiquidate, localToPurchase) = _calculateLocalToPurchase(
            c.factors,
            c.liquidationDiscount,
            fCashLiquidationPV,
            fCashToLiquidate
        );

        // As we liquidate here the local available and collateral available will change. Update values accordingly so
        // that the limits will be hit on subsequent iterations.
        c.factors.collateralAvailable = c.factors.collateralAvailable.sub(
            fCashToLiquidate.mul(riskAdjustedDiscountFactor).div(Constants.RATE_PRECISION)
        );
        // Local available does not have any buffers applied to it
        c.factors.localAvailable = c.factors.localAvailable.add(localToPurchase);

        return (fCashToLiquidate, localToPurchase);
    }

    /// @notice Allows the liquidator to purchase fCash in a different currency that a debt is denominated in.
    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint256 collateralCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint256 blockTime
    ) internal {
        require(c.factors.localAvailable < 0, "No local debt");
        require(c.factors.collateralAvailable > 0, "No collateral assets");

        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);
        (c.benefitRequired, c.liquidationDiscount) = _calculateCrossCurrencyBenefitAndDiscount(
            c.factors
        );

        for (uint256 i; i < fCashMaturities.length; i++) {
            int256 notional =
                _getfCashNotional(liquidateAccount, c, collateralCurrency, fCashMaturities[i]);
            if (notional == 0) continue;

            c.fCashNotionalTransfers[i] = _calculateCrossCurrencyfCashToLiquidate(
                c,
                fCashMaturities[i],
                blockTime,
                int256(maxfCashLiquidateAmounts[i]),
                notional
            );

            if (c.benefitRequired <= 0 || c.factors.collateralAvailable <= 0) break;
        }
    }

    struct WithdrawFactors {
        int256 netCashIncrease;
        int256 fCash;
        int256 assetCash;
        int256 totalIncentivePaid;
        int256 totalCashClaim;
        int256 incentivePaid;
    }

    /// @notice Withdraws liquidity tokens from a portfolio. Assumes that no trading will occur during
    /// liquidation so portfolioState.newAssets.length == 0. If liquidity tokens are settled they will
    /// not create new assets, the net fCash asset will replace the liquidity token asset.
    function _withdrawLocalLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint256 blockTime,
        int256 assetAmountRemaining
    ) internal view returns (WithdrawFactors memory, int256) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        // Do this to deal with stack issues
        WithdrawFactors memory w;

        // NOTE: even if stored assets have been modified in memory as a result of the Asset.getRiskAdjustedPortfolioValue
        // method getting the haircut value will still work here because we do not reference the fCash value.
        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (
                !AssetHandler.isLiquidityToken(asset.assetType) ||
                asset.currencyId != factors.cashGroup.currencyId
            ) continue;

            MarketParameters memory market =
                factors.cashGroup.getMarket(factors.markets, asset.assetType - 1, blockTime, true);

            // NOTE: we do not give any credit to the haircut fCash in this procedure but it will end up adding
            // additional collateral value back into the account. It's probably too complex to deal with this so
            // we will just leave it as such.
            (w.assetCash, w.fCash) = asset.getCashClaims(market);

            {
                // We can only recollateralize the local currency using the part of the liquidity token that
                // between the pre-haircut cash claim and the post-haircut cash claim. Part of the cash raised
                // is paid out as an incentive so that must be accounted for.
                // netCashIncrease = cashClaim * (1 - haircut)
                // netCashIncrease = netCashToAccount + incentivePaid
                // incentivePaid = netCashIncrease * incentive
                int256 haircut = int256(factors.cashGroup.getLiquidityHaircut(asset.assetType));
                w.netCashIncrease = w.assetCash.mul(Constants.PERCENTAGE_DECIMALS.sub(haircut)).div(
                    Constants.PERCENTAGE_DECIMALS
                );
            }
            w.incentivePaid = w.netCashIncrease.mul(Constants.TOKEN_REPO_INCENTIVE_PERCENT).div(
                Constants.PERCENTAGE_DECIMALS
            );

            // (netCashToAccount <= assetAmountRemaining)
            if (w.netCashIncrease.subNoNeg(w.incentivePaid) <= assetAmountRemaining) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // assetAmountRemaining = assetAmountRemaining - netCashToAccount
                // netCashToAccount = netCashIncrease - incentivePaid
                // overflow checked above
                assetAmountRemaining =
                    assetAmountRemaining -
                    w.netCashIncrease.sub(w.incentivePaid);
            } else {
                // incentivePaid
                w.incentivePaid = assetAmountRemaining
                    .mul(Constants.TOKEN_REPO_INCENTIVE_PERCENT)
                    .div(Constants.PERCENTAGE_DECIMALS);

                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                int256 tokensToRemove =
                    asset.notional.mul(assetAmountRemaining).div(w.netCashIncrease);

                (w.assetCash, w.fCash) = market.removeLiquidity(tokensToRemove);

                // Remove liquidity token balance
                portfolioState.storedAssets[i].notional = asset.notional.subNoNeg(tokensToRemove);
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;
                assetAmountRemaining = 0;
            }

            w.totalIncentivePaid = w.totalIncentivePaid.add(w.incentivePaid);
            w.totalCashClaim = w.totalCashClaim.add(w.assetCash);

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                factors.cashGroup.currencyId,
                asset.maturity,
                Constants.FCASH_ASSET_TYPE,
                w.fCash,
                false
            );

            if (assetAmountRemaining == 0) break;
        }

        return (w, assetAmountRemaining);
    }

    /// @dev Similar to withdraw liquidity tokens, except there is no incentive paid and we do not worry about
    /// haircut amounts, we simply withdraw as much collateral as needed.
    function _withdrawCollateralLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint256 blockTime,
        int256 collateralToWithdraw
    ) internal view returns (int256) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (
                !AssetHandler.isLiquidityToken(asset.assetType) ||
                asset.currencyId != factors.cashGroup.currencyId
            ) continue;

            MarketParameters memory market =
                factors.cashGroup.getMarket(factors.markets, asset.assetType - 1, blockTime, true);
            (int256 cashClaim, int256 fCashClaim) = asset.getCashClaims(market);

            if (cashClaim <= collateralToWithdraw) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // overflow checked above
                collateralToWithdraw = collateralToWithdraw - cashClaim;
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // notional * collateralToWithdraw / cashClaim
                int256 tokensToRemove = asset.notional.mul(collateralToWithdraw).div(cashClaim);
                (cashClaim, fCashClaim) = market.removeLiquidity(tokensToRemove);

                // Remove liquidity token balance
                portfolioState.storedAssets[i].notional = asset.notional.subNoNeg(tokensToRemove);
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;
                collateralToWithdraw = 0;
            }

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                factors.cashGroup.currencyId,
                asset.maturity,
                Constants.FCASH_ASSET_TYPE,
                fCashClaim,
                false
            );

            if (collateralToWithdraw == 0) return 0;
        }

        return collateralToWithdraw;
    }
}
