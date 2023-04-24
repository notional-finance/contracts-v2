// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    ETHRate,
    PortfolioAsset,
    CashGroupParameters,
    PortfolioState,
    Token,
    AccountContext,
    PrimeRate,
    LiquidationFactors
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {Emitter} from "../Emitter.sol";
import {AssetHandler} from "../valuation/AssetHandler.sol";
import {CashGroup} from "../markets/CashGroup.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {TokenHandler} from "../balances/TokenHandler.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";
import {ExchangeRate} from "../valuation/ExchangeRate.sol";
import {PortfolioHandler} from "../portfolio/PortfolioHandler.sol";
import {BitmapAssetsHandler} from "../portfolio/BitmapAssetsHandler.sol";

import {AccountContextHandler} from "../AccountContextHandler.sol";
import {LiquidationHelpers} from "./LiquidationHelpers.sol";

import {FreeCollateralExternal} from "../../external/FreeCollateralExternal.sol";
import {SettleAssetsExternal} from "../../external/SettleAssetsExternal.sol";

library LiquidatefCash {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using PrimeRateLib for PrimeRate;
    using AccountContextHandler for AccountContext;
    using TokenHandler for Token;

    event LiquidatefCashEvent(
        address indexed liquidated,
        address indexed liquidator,
        uint16 localCurrencyId,
        uint16 fCashCurrency,
        int256 netLocalFromLiquidator,
        uint256[] fCashMaturities,
        int256[] fCashNotionalTransfer
    );

    /// @notice Calculates the risk adjusted and liquidation discount factors used when liquidating fCash. The
    /// The risk adjusted discount factor is used to value fCash, the liquidation discount factor is used to 
    /// calculate the price of the fCash asset at a discount to the risk adjusted factor.
    /// @dev During local fCash liquidation, collateralCashGroup will be set to the local currency cash group
    function _calculatefCashDiscounts(
        LiquidationFactors memory factors,
        uint256 maturity,
        uint256 blockTime,
        bool isNotionalPositive
    ) private view returns (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) {
        uint256 oracleRate = factors.collateralCashGroup.calculateOracleRate(maturity, blockTime);

        if (isNotionalPositive) {
            // This is the discount factor used to calculate the fCash present value during free collateral
            riskAdjustedDiscountFactor = AssetHandler.getRiskAdjustedfCashDiscount(
                factors.collateralCashGroup, maturity, blockTime
            );

            // This is the discount factor that liquidators get to purchase fCash at, will be larger than
            // the risk adjusted discount factor.
            liquidationDiscountFactor = AssetHandler.getDiscountFactor(
                maturity.sub(blockTime),
                oracleRate.add(factors.collateralCashGroup.getLiquidationfCashHaircut())
            );
        } else {
            riskAdjustedDiscountFactor = AssetHandler.getRiskAdjustedDebtDiscount(
                factors.collateralCashGroup, maturity, blockTime
            );

            uint256 buffer = factors.collateralCashGroup.getLiquidationDebtBuffer();
            liquidationDiscountFactor = AssetHandler.getDiscountFactor(
                maturity.sub(blockTime),
                oracleRate < buffer ? 0 : oracleRate.sub(buffer)
            );
        }
    }

    /// @notice Returns the fCashNotional for a given account, currency and maturity.
    /// @return the notional amount
    function _getfCashNotional(
        address liquidateAccount,
        fCashContext memory context,
        uint256 currencyId,
        uint256 maturity
    ) private view returns (int256) {
        if (context.accountContext.bitmapCurrencyId == currencyId) {
            return
                BitmapAssetsHandler.getifCashNotional(liquidateAccount, currencyId, maturity);
        }

        PortfolioAsset[] memory portfolio = context.portfolio.storedAssets;
        // Loop backwards through the portfolio since we require fCash maturities to be sorted
        // descending
        for (uint256 i = portfolio.length; (i--) > 0;) {
            PortfolioAsset memory asset = portfolio[i];
            if (
                asset.currencyId == currencyId &&
                asset.assetType == Constants.FCASH_ASSET_TYPE &&
                asset.maturity == maturity
            ) {
                return asset.notional;
            }
        }

        // If asset is not found then we return zero instead of failing in the case that a previous
        // liquidation has already liquidated the specified fCash asset. This liquidation can continue
        // to the next specified fCash asset.
        return 0;
    }

    struct fCashContext {
        AccountContext accountContext;
        LiquidationFactors factors;
        PortfolioState portfolio;
        int256 localCashBalanceUnderlying;
        int256 underlyingBenefitRequired;
        int256 localPrimeCashFromLiquidator;
        int256 liquidationDiscount;
        int256[] fCashNotionalTransfers;
    }

    /// @notice Allows the liquidator to purchase fCash in the same currency that a debt is denominated in. It's
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
        // If local asset available == 0 then there is nothing that this liquidation can do.
        require(c.factors.localPrimeAvailable != 0);

        // If local available is positive then we can trade fCash to cash to increase the total free
        // collateral of the account. Local available will always increase due to the removal of the haircut
        // on fCash assets as they are converted to cash. The increase will be the difference between the
        // risk adjusted haircut value and the liquidation value. Note that negative fCash assets can also be
        // liquidated via this method, the liquidator will receive negative fCash and cash as a result -- in effect
        // they will be borrowing at a discount to the oracle rate.
        c.underlyingBenefitRequired = LiquidationHelpers.calculateLocalLiquidationUnderlyingRequired(
            c.factors.localPrimeAvailable,
            c.factors.netETHValue,
            c.factors.localETHRate
        );

        for (uint256 i = 0; i < fCashMaturities.length; i++) {
            // Require that fCash maturities are sorted descending. This ensures that a maturity can only
            // be specified exactly once. It also ensures that the longest dated assets (most risky) are
            // liquidated first.
            if (i > 0) require(fCashMaturities[i - 1] > fCashMaturities[i]);

            int256 notional =
                _getfCashNotional(liquidateAccount, c, localCurrency, fCashMaturities[i]);
            // If a notional balance is negative, ensure that there is some local cash balance to
            // purchase for the liquidation. Allow a zero cash balance so that the loop continues even if
            // all of the cash balance has been transferred.
            if (notional < 0) require(c.localCashBalanceUnderlying >= 0); // dev: insufficient cash balance
            if (notional == 0) continue;

            // If notional > 0 then liquidation discount > risk adjusted discount
            //    this is because the liquidation oracle rate < risk adjusted oracle rate
            // If notional < 0 then liquidation discount < risk adjusted discount
            //    this is because the liquidation oracle rate > risk adjusted oracle rate
            (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) =
                _calculatefCashDiscounts(c.factors, fCashMaturities[i], blockTime, notional > 0);

            // The benefit to the liquidated account is the difference between the liquidation discount factor
            // and the risk adjusted discount factor:
            // localCurrencyBenefit = fCash * (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            // fCash = localCurrencyBenefit / (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            // abs is used here to ensure positive values
            c.fCashNotionalTransfers[i] = c.underlyingBenefitRequired
            // NOTE: Governance should be set such that these discount factors are unlikely to be zero. It's
            // possible that the interest rates are so low or that the fCash asset is very close to maturity
            // that this situation can occur. In this case, there would be almost zero benefit to liquidating
            // the particular fCash asset.
                .divInRatePrecision(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor).abs());

            // fCashNotionalTransfers[i] is always positive at this point. The max liquidate amount is
            // calculated using the absolute value of the notional amount to ensure that the inequalities
            // operate properly inside calculateLiquidationAmount.
            c.fCashNotionalTransfers[i] = LiquidationHelpers.calculateLiquidationAmount(
                c.fCashNotionalTransfers[i], // liquidate amount required
                notional.abs(), // max total balance
                SafeInt256.toInt(maxfCashLiquidateAmounts[i]) // user specified maximum
            );

            // This is the price the liquidator pays of the fCash that has been liquidated
            int256 fCashLiquidationValueUnderlying =
                c.fCashNotionalTransfers[i].mulInRatePrecision(liquidationDiscountFactor);

            if (notional < 0) {
                // In the case of negative notional amounts, limit the amount of liquidation to the local cash
                // balance in underlying so that the liquidated account does not incur a negative cash balance.
                if (fCashLiquidationValueUnderlying > c.localCashBalanceUnderlying) {
                    // We know that all these values are positive at this point.
                    c.fCashNotionalTransfers[i] = c.fCashNotionalTransfers[i]
                        .mul(c.localCashBalanceUnderlying)
                        .div(fCashLiquidationValueUnderlying);
                    fCashLiquidationValueUnderlying = c.localCashBalanceUnderlying;
                }

                // Flip the sign when the notional is negative
                c.fCashNotionalTransfers[i] = c.fCashNotionalTransfers[i].neg();
                // When the notional is negative, cash balance will be transferred to the liquidator instead of
                // being provided by the liquidator.
                fCashLiquidationValueUnderlying = fCashLiquidationValueUnderlying.neg();
            }

            // NOTE: localPrimeCashFromLiquidator is actually in underlying terms during this loop, it is converted to asset terms just once
            // at the end of the loop to limit loss of precision
            c.localPrimeCashFromLiquidator = c.localPrimeCashFromLiquidator.add(
                fCashLiquidationValueUnderlying
            );
            c.localCashBalanceUnderlying = c.localCashBalanceUnderlying.add(
                fCashLiquidationValueUnderlying
            );

            // Deduct the total benefit gained from liquidating this fCash position
            c.underlyingBenefitRequired = c.underlyingBenefitRequired.sub(
                c.fCashNotionalTransfers[i]
                    .mulInRatePrecision(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor))
                    .abs()
            );

            // Once the underlying benefit is reduced below zero then we have liquidated a sufficient amount
            if (c.underlyingBenefitRequired <= 0) break;
        }

        // Convert local to purchase to asset terms for transfers
        c.localPrimeCashFromLiquidator = c.factors.localPrimeRate.convertFromUnderlying(
            c.localPrimeCashFromLiquidator
        );
    }

    /// @notice Allows the liquidator to purchase fCash in a different currency that a debt is denominated in.
    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint256 collateralCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint256 blockTime
    ) internal view {
        require(c.factors.localPrimeAvailable < 0); // dev: no local debt
        require(c.factors.collateralAssetAvailable > 0); // dev: no collateral assets

        {
            // NOTE: underlying benefit is return in asset terms from this function, convert it to underlying
            // for the purposes of this method. The underlyingBenefitRequired is denominated in collateral currency
            // and equivalent to convertToCollateral(netETHValue.neg()).
            (c.underlyingBenefitRequired, c.liquidationDiscount) = LiquidationHelpers
                .calculateCrossCurrencyFactors(c.factors);
            c.underlyingBenefitRequired = c.factors.collateralCashGroup.primeRate.convertToUnderlying(
                c.underlyingBenefitRequired
            );
        }

        for (uint256 i = 0; i < fCashMaturities.length; i++) {
            // Require that fCash maturities are sorted descending. This ensures that a maturity can only
            // be specified exactly once. It also ensures that the longest dated assets (most risky) are
            // liquidated first.
            if (i > 0) require(fCashMaturities[i - 1] > fCashMaturities[i]);

            int256 notional =
                _getfCashNotional(liquidateAccount, c, collateralCurrency, fCashMaturities[i]);
            if (notional == 0) continue;
            require(notional > 0); // dev: invalid fcash asset

            c.fCashNotionalTransfers[i] = _calculateCrossCurrencyfCashToLiquidate(
                c,
                fCashMaturities[i],
                blockTime,
                SafeInt256.toInt(maxfCashLiquidateAmounts[i]),
                notional
            );

            if (
                c.underlyingBenefitRequired <= 0 ||
                // These two factors will be capped and floored at zero inside `_limitPurchaseByAvailableAmounts`
                c.factors.collateralAssetAvailable == 0 ||
                c.factors.localPrimeAvailable == 0
            ) break;
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
            _calculatefCashDiscounts(c.factors, maturity, blockTime, true);

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
        int256 benefitDivisor;
        {
            // prettier-ignore
            int256 termTwo = (
                    c.factors.localETHRate.buffer.mul(Constants.PERCENTAGE_DECIMALS).div(
                        c.liquidationDiscount
                    )
                ).sub(c.factors.collateralETHRate.haircut);
            termTwo = liquidationDiscountFactor.mul(termTwo).div(Constants.PERCENTAGE_DECIMALS);
            int256 termOne = liquidationDiscountFactor.sub(riskAdjustedDiscountFactor);
            benefitDivisor = termOne.add(termTwo);
        }

        int256 fCashToLiquidate =
            c.underlyingBenefitRequired.divInRatePrecision(benefitDivisor);

        fCashToLiquidate = LiquidationHelpers.calculateLiquidationAmount(
            fCashToLiquidate,
            notional,
            maxfCashLiquidateAmount
        );

        // Ensures that local available does not go above zero and collateral available does not go below zero
        int256 localPrimeCashFromLiquidator;
        (fCashToLiquidate, localPrimeCashFromLiquidator) = _limitPurchaseByAvailableAmounts(
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
        int256 benefitGainedUnderlying = fCashToLiquidate.mulInRatePrecision(benefitDivisor);

        c.underlyingBenefitRequired = c.underlyingBenefitRequired.sub(benefitGainedUnderlying);
        c.localPrimeCashFromLiquidator = c.localPrimeCashFromLiquidator.add(
            localPrimeCashFromLiquidator
        );

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
        int256 fCashLiquidationUnderlyingPV = fCashToLiquidate.mulInRatePrecision(liquidationDiscountFactor);
        int256 fCashRiskAdjustedUnderlyingPV = fCashToLiquidate.mulInRatePrecision(riskAdjustedDiscountFactor);

        // Ensures that collateralAssetAvailable does not go below zero
        int256 collateralUnderlyingAvailable =
            c.factors.collateralCashGroup.primeRate.convertToUnderlying(c.factors.collateralAssetAvailable);
        if (fCashRiskAdjustedUnderlyingPV > collateralUnderlyingAvailable) {
            // If inside this if statement then all collateralAssetAvailable should be coming from fCashRiskAdjustedPV
            // collateralAssetAvailable = fCashRiskAdjustedPV
            // collateralAssetAvailable = fCashToLiquidate * riskAdjustedDiscountFactor
            // fCashToLiquidate = collateralAssetAvailable / riskAdjustedDiscountFactor
            fCashToLiquidate = collateralUnderlyingAvailable.divInRatePrecision(riskAdjustedDiscountFactor);

            fCashRiskAdjustedUnderlyingPV = collateralUnderlyingAvailable;

            // Recalculate the PV at the new liquidation amount
            fCashLiquidationUnderlyingPV = fCashToLiquidate.mulInRatePrecision(liquidationDiscountFactor);
        }

        int256 localPrimeCashFromLiquidator;
        (fCashToLiquidate, localPrimeCashFromLiquidator) = LiquidationHelpers.calculateLocalToPurchase(
            c.factors,
            c.liquidationDiscount,
            fCashLiquidationUnderlyingPV,
            fCashToLiquidate
        );

        // As we liquidate here the local available and collateral available will change. Update values accordingly so
        // that the limits will be hit on subsequent iterations.
        c.factors.collateralAssetAvailable = c.factors.collateralAssetAvailable.subNoNeg(
            c.factors.collateralCashGroup.primeRate.convertFromUnderlying(fCashRiskAdjustedUnderlyingPV)
        );
        // Cannot have a negative value here, local asset available should always increase as a result of
        // cross currency liquidation.
        require(localPrimeCashFromLiquidator >= 0);
        c.factors.localPrimeAvailable = c.factors.localPrimeAvailable.add(
            localPrimeCashFromLiquidator
        );

        return (fCashToLiquidate, localPrimeCashFromLiquidator);
    }

    /**
     * @notice Finalizes fCash liquidation for both local and cross currency liquidation.
     * @dev Since fCash liquidation only ever results in transfers of cash and fCash we
     * don't use BalanceHandler.finalize here to save some bytecode space (desperately
     * needed for this particular contract.) We use a special function just for fCash
     * liquidation to update the cash balance on the liquidated account.
     */
    function finalizefCashLiquidation(
        address liquidateAccount,
        address liquidator,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        fCashContext memory c
    ) internal returns (int256[] memory, int256) {
        Token memory token = TokenHandler.getUnderlyingToken(localCurrency);
        AccountContext memory liquidatorContext = AccountContextHandler.getAccountContext(liquidator);
        int256 netLocalFromLiquidator = c.localPrimeCashFromLiquidator;
        PrimeRate memory primeRate = PrimeRateLib.buildPrimeRateStateful(localCurrency);

        if (token.hasTransferFee && netLocalFromLiquidator > 0) {
            // If a token has a transfer fee then it must have been deposited prior to the liquidation
            // or else we won't be able to net off the correct amount. We also require that the account
            // does not have debt so that we do not have to run a free collateral check here
            require(liquidatorContext.hasDebt == 0x00, "Has debt"); // dev: token has transfer fee, no liquidator balance

            // Net off the cash balance for the liquidator. If the cash balance goes negative here then it will revert.
            BalanceHandler.setBalanceStorageForfCashLiquidation(
                liquidator,
                liquidatorContext,
                localCurrency,
                netLocalFromLiquidator.neg(),
                primeRate
            );
        } else if (netLocalFromLiquidator > 0) {
            // In any other case, do a token transfer for the liquidator (either into or out of Notional)
            // and do not credit any cash balance. That will be done just for the liquidated account.
            TokenHandler.depositExactToMintPrimeCash(
                liquidator,
                localCurrency,
                netLocalFromLiquidator,
                primeRate,
                false // ETH will be returned natively to the liquidator
            );
        } else {
            // In negative fCash liquidation, netLocalFromLiquidator < 0, meaning the liquidator is paid
            // cash and will receive it in their cash balance. This ensures that there is greater likelihood
            // of passing a free collateral check. Negative fCash liquidation is profitable from a PnL perspective
            // but will not necessarily increase the free collateral of the liquidator due to fCash discounts
            // and haircuts.
            BalanceHandler.setBalanceStorageForfCashLiquidation(
                liquidator,
                liquidatorContext,
                localCurrency,
                netLocalFromLiquidator.neg(),
                primeRate
            );
        }

        // If netLocalFromLiquidator < 0, will flip the from and to addresses
        Emitter.emitTransferPrimeCash(liquidator, liquidateAccount, localCurrency, netLocalFromLiquidator);

        BalanceHandler.setBalanceStorageForfCashLiquidation(
            liquidateAccount,
            c.accountContext,
            localCurrency,
            netLocalFromLiquidator,
            primeRate
        );

        bool liquidatorIncursDebt;
        (liquidatorIncursDebt, liquidatorContext) =
            _transferAssets(
                liquidateAccount,
                liquidator,
                liquidatorContext,
                fCashCurrency,
                fCashMaturities,
                c
            );

        emit LiquidatefCashEvent(
            liquidateAccount,
            liquidator,
            localCurrency,
            fCashCurrency,
            c.localPrimeCashFromLiquidator,
            fCashMaturities,
            c.fCashNotionalTransfers
        );

        liquidatorContext.setAccountContext(liquidator);
        c.accountContext.setAccountContext(liquidateAccount);

        // If the liquidator takes on debt as a result of the liquidation and has debt in their portfolio
        // then they must have a free collateral check. It's possible for the liquidator to skip this if the
        // negative fCash incurred from the liquidation nets off against an existing fCash position.
        if (liquidatorIncursDebt && liquidatorContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(liquidator);
        }

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
    }

    function _transferAssets(
        address liquidateAccount,
        address liquidator,
        AccountContext memory liquidatorContext,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        fCashContext memory c
    ) private returns (bool, AccountContext memory) {
        (PortfolioAsset[] memory assets, bool liquidatorIncursDebt) =
            _makeAssetArray(fCashCurrency, fCashMaturities, c.fCashNotionalTransfers);

        (c.accountContext, liquidatorContext) = SettleAssetsExternal.transferAssets(
            liquidateAccount,
            liquidator,
            c.accountContext,
            liquidatorContext,
            assets
        );

        return (liquidatorIncursDebt, liquidatorContext);
    }

    function _makeAssetArray(
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        int256[] memory fCashNotionalTransfers
    ) private pure returns (PortfolioAsset[] memory, bool) {
        require(fCashMaturities.length == fCashNotionalTransfers.length);

        PortfolioAsset[] memory assets = new PortfolioAsset[](fCashMaturities.length);
        bool liquidatorIncursDebt = false;
        for (uint256 i = 0; i < fCashMaturities.length; i++) {
            PortfolioAsset memory asset = assets[i];
            asset.currencyId = fCashCurrency;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = fCashNotionalTransfers[i];
            asset.maturity = fCashMaturities[i];

            if (asset.notional < 0) liquidatorIncursDebt = true;
        }

        return (assets, liquidatorIncursDebt);
    }
}
