// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./LiquidationHelpers.sol";
import "../AccountContextHandler.sol";
import "../valuation/AssetHandler.sol";
import "../markets/CashGroup.sol";
import "../valuation/ExchangeRate.sol";
import "../portfolio/PortfolioHandler.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library LiquidatefCash {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using AccountContextHandler for AccountContext;
    using PortfolioHandler for PortfolioState;

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

    struct fCashContext {
        AccountContext accountContext;
        LiquidationFactors factors;
        PortfolioState portfolio;
        int256 benefitRequired;
        int256 localToPurchase;
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
        if (c.factors.localAvailable > 0) {
            // If local available is positive then we can bring it down to zero
            //prettier-ignore
            c.benefitRequired = c.factors.localETHRate
                .convertETHTo(c.factors.netETHValue.neg())
                .mul(Constants.PERCENTAGE_DECIMALS)
                // If the haircut is zero then this will revert which is the correct result. A currency with
                // a haircut to zero does not affect free collateral.
                .div(c.factors.localETHRate.haircut);
        } else {
            // If local available is negative then we can bring it up to zero
            c.benefitRequired = c.factors.localAvailable.neg();
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
            // fCash = localCurrencyBenefit / (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            c.fCashNotionalTransfers[i] = c.benefitRequired.mul(Constants.RATE_PRECISION).div(
                liquidationDiscountFactor.sub(riskAdjustedDiscountFactor)
            );

            c.fCashNotionalTransfers[i] = LiquidationHelpers.calculateLiquidationAmount(
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
        fCashToLiquidate = LiquidationHelpers.calculateLiquidationAmount(
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

        int256 fCashRiskAdjustedPV =
            fCashToLiquidate.mul(riskAdjustedDiscountFactor).div(Constants.RATE_PRECISION);

        // Ensures that collateralAvailable does not go below zero
        if (fCashRiskAdjustedPV > c.factors.collateralAvailable) {
            // If inside this if statement then all collateralAvailable should be coming from fCashRiskAdjustedPV
            // collateralAvailable = fCashRiskAdjustedPV
            // collateralAvailable = fCashToLiquidate * riskAdjustedDiscountFactor
            // fCashToLiquidate = collateralAvailable / riskAdjustedDiscountFactor
            fCashToLiquidate = c.factors.collateralAvailable.mul(Constants.RATE_PRECISION).div(
                riskAdjustedDiscountFactor
            );

            fCashRiskAdjustedPV = c.factors.collateralAvailable;

            // Recalculate the PV at the new liquidation amount
            fCashLiquidationPV = fCashToLiquidate.mul(liquidationDiscountFactor).div(
                Constants.RATE_PRECISION
            );
        }

        int256 localToPurchase;
        (fCashToLiquidate, localToPurchase) = LiquidationHelpers.calculateLocalToPurchase(
            c.factors,
            c.liquidationDiscount,
            fCashLiquidationPV,
            fCashToLiquidate
        );

        // As we liquidate here the local available and collateral available will change. Update values accordingly so
        // that the limits will be hit on subsequent iterations.
        c.factors.collateralAvailable = c.factors.collateralAvailable.subNoNeg(fCashRiskAdjustedPV);
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
    ) internal view {
        require(c.factors.localAvailable < 0, "No local debt");
        require(c.factors.collateralAvailable > 0, "No collateral assets");

        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);
        (c.benefitRequired, c.liquidationDiscount) = LiquidationHelpers
            .calculateCrossCurrencyBenefitAndDiscount(c.factors);

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

    /// @dev Finalizes fCash liquidation for both local and cross currency liquidation
    function finalizefCashLiquidation(
        address liquidateAccount,
        address liquidator,
        uint256 localCurrency,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        fCashContext memory c,
        uint256 blockTime
    ) internal returns (int256[] memory, int256) {
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                liquidator,
                localCurrency,
                c.localToPurchase.neg(),
                0
            );

        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            c.accountContext,
            c.localToPurchase
        );

        _transferAssets(
            liquidateAccount,
            liquidator,
            liquidatorContext,
            fCashCurrency,
            fCashMaturities,
            c
        );

        liquidatorContext.setAccountContext(msg.sender);
        c.accountContext.setAccountContext(liquidateAccount);

        return (c.fCashNotionalTransfers, c.localToPurchase);
    }

    function _transferAssets(
        address liquidateAccount,
        address liquidator,
        AccountContext memory liquidatorContext,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        fCashContext memory c
    ) private {
        PortfolioAsset[] memory assets =
            _makeAssetArray(fCashCurrency, fCashMaturities, c.fCashNotionalTransfers);

        liquidatorContext = TransferAssets.placeAssetsInAccount(
            liquidator,
            liquidatorContext,
            assets
        );
        TransferAssets.invertNotionalAmountsInPlace(assets);

        if (c.accountContext.bitmapCurrencyId == 0) {
            c.portfolio.addMultipleAssets(assets);
            AccountContextHandler.storeAssetsAndUpdateContext(
                c.accountContext,
                liquidateAccount,
                c.portfolio,
                false // Although this is liquidation, we should not allow past max assets here
            );
        } else {
            BitmapAssetsHandler.addMultipleifCashAssets(liquidateAccount, c.accountContext, assets);
        }
    }

    function _makeAssetArray(
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        int256[] memory fCashNotionalTransfers
    ) private pure returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = new PortfolioAsset[](fCashMaturities.length);
        for (uint256 i; i < assets.length; i++) {
            assets[i].currencyId = fCashCurrency;
            assets[i].assetType = Constants.FCASH_ASSET_TYPE;
            assets[i].notional = fCashNotionalTransfers[i];
            assets[i].maturity = fCashMaturities[i];
        }

        return assets;
    }
}
