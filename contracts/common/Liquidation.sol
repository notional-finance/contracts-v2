// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetHandler.sol";
import "./FreeCollateral.sol";
import "./ExchangeRate.sol";
import "./CashGroup.sol";
import "../actions/SettleAssetsExternal.sol";
import "../storage/AccountContextHandler.sol";
import "../storage/BitmapAssetsHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Liquidation {
    using SafeMath for uint;
    using SafeInt256 for int;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using AccountContextHandler for AccountStorage;
    using Market for MarketParameters;

    int internal constant MAX_LIQUIDATION_PORTION = 40;
    int internal constant TOKEN_REPO_INCENTIVE_PERCENT = 10;

    /**
     * @notice Settles accounts and returns liquidation factors for all of the liquidation actions.
     */
    function preLiquidationActions(
        address liquidateAccount,
        uint localCurrency,
        uint collateralCurrency,
        uint blockTime
    ) internal returns (AccountStorage memory, LiquidationFactors memory, PortfolioState memory) {
        require(localCurrency != 0);
        // Collateral currency must be unset or not equal to the local currency
        require(collateralCurrency == 0 || collateralCurrency != localCurrency);
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(liquidateAccount);

        if (accountContext.mustSettleAssets()) {
            accountContext = SettleAssetsExternal.settleAssetsAndFinalize(liquidateAccount);
        }

        (
            LiquidationFactors memory factors,
            PortfolioAsset[] memory portfolio
        ) = FreeCollateral.getLiquidationFactors(
            liquidateAccount,
            accountContext,
            blockTime,
            localCurrency,
            collateralCurrency
        );

        PortfolioState memory portfolioState = PortfolioState({
            storedAssets: portfolio,
            newAssets: new PortfolioAsset[](0),
            lastNewAssetIndex: 0,
            storedAssetLength: portfolio.length
        });

        return (accountContext, factors, portfolioState);
    }

    /**
     * @notice We allow liquidators to purchase up to MAX_LIQUIDATION_PORTION percentage of collateral
     * assets during liquidation to recollateralize an account as long as it does not also put the account
     * further into negative free collateral (i.e. constraints on local available and collateral available).
     * Additionally, we allow the liquidator to specify a maximum amount of collateral they would like to
     * purchase so we also enforce that limit here.
     */
    function calculateMaxLiquidationAmount(
        int initialAmountToLiquidate,
        int maxTotalBalance,
        int userSpecifiedMaximum
    ) private pure returns (int) {
        int maxAllowedAmount = maxTotalBalance
            .mul(MAX_LIQUIDATION_PORTION)
            .div(CashGroup.PERCENTAGE_DECIMALS);

        int result = initialAmountToLiquidate;

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

    function calculateCrossCurrencyBenefitAndDiscount(
        LiquidationFactors memory factors
    ) private pure returns (int, int) {
        int liquidationDiscount;
        // This calculation returns the amount of benefit that selling collateral for local currency will
        // be back to the account.
        int benefitRequired = factors.collateralETHRate.convertETHTo(factors.netETHValue.neg())
            .mul(ExchangeRate.MULTIPLIER_DECIMALS)
            // If the haircut is zero here the transaction will revert, which is the correct result. Liquidating
            // collateral with a zero haircut will have no net benefit back to the liquidated account.
            .div(factors.collateralETHRate.haircut);

        if (factors.collateralETHRate.liquidationDiscount > factors.localETHRate.liquidationDiscount) {
            liquidationDiscount = factors.collateralETHRate.liquidationDiscount;
        } else {
            liquidationDiscount = factors.localETHRate.liquidationDiscount;
        }

        return (benefitRequired, liquidationDiscount);
    }

    /**
     * @notice Calculates the local to purchase in cross currency liquidations. Ensures that local to purchase
     * is not so large that the account is put further into debt.
     */
    function calculateLocalToPurchase(
        LiquidationFactors memory factors,
        int liquidationDiscount,
        int collateralPresentValue,
        int collateralBalanceToSell
    ) private pure returns (int, int) {
        // Converts collateral present value to the local amount along with the liquidation discount.
        // localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)
        int localToPurchase = collateralPresentValue
            .mul(ExchangeRate.MULTIPLIER_DECIMALS)
            .mul(factors.localETHRate.rateDecimals)
            .div(ExchangeRate.exchangeRate(factors.localETHRate, factors.collateralETHRate))
            .div(liquidationDiscount);

        if (localToPurchase > factors.localAvailable.neg()) {
            // If the local to purchase will put the local available into negative territory we
            // have to cut the collateral purchase amount back. Putting local available into negative
            // territory will force the liquidated account to incur more debt.
            collateralBalanceToSell = collateralBalanceToSell
                .mul(factors.localAvailable.neg())
                .div(localToPurchase);

            localToPurchase = factors.localAvailable.neg();
        }

        return (collateralBalanceToSell, localToPurchase);
    }

    /**
     * @notice Calculates the two discount factors relevant when liquidating fCash.
     */
    function calculatefCashDiscounts(
        LiquidationFactors memory factors,
        uint maturity,
        uint blockTime
    ) private view returns (int, int) {
        uint oracleRate = factors.cashGroup.getOracleRate(factors.markets, maturity, blockTime);

        uint timeToMaturity = maturity.sub(blockTime);
        // This is the discount factor used to calculate the fCash present value during free collateral
        int riskAdjustedDiscountFactor = AssetHandler.getDiscountFactor(
            timeToMaturity,
            oracleRate.add(factors.cashGroup.getfCashHaircut())
        );
        // This is the discount factor that liquidators get to purchase fCash at, will be larger than
        // the risk adjusted discount factor.
        int liquidationDiscountFactor = AssetHandler.getDiscountFactor(
            timeToMaturity,
            oracleRate.add(factors.cashGroup.getLiquidationfCashHaircut())
        );

        return (riskAdjustedDiscountFactor, liquidationDiscountFactor);
    }

    function hasLiquidityTokens(
        PortfolioAsset[] memory portfolio,
        uint currencyId
    ) private pure returns (bool) {
        for (uint i; i < portfolio.length; i++) {
            if (portfolio[i].currencyId == currencyId && AssetHandler.isLiquidityToken(portfolio[i].assetType)) {
                return true;
            }
        }

        return false;
    }

    function getfCashNotional(
        address liquidateAccount,
        fCashContext memory context,
        uint currencyId,
        uint maturity
    ) private view returns (int) {
        if (context.accountContext.bitmapCurrencyId == currencyId) {
            int notional = BitmapAssetsHandler.getifCashNotional(liquidateAccount, currencyId, maturity);
            require(notional > 0, "Invalid fCash asset");
        }

        PortfolioAsset[] memory portfolio = context.portfolio.storedAssets;
        for (uint i; i < portfolio.length; i++) {
            if (portfolio[i].currencyId == currencyId
                && portfolio[i].assetType == AssetHandler.FCASH_ASSET_TYPE
                && portfolio[i].maturity == maturity) {
                require(portfolio[i].notional > 0, "Invalid fCash asset");
                return portfolio[i].notional;
            }
        }

        // If asset is not found then we return zero instead of failing in the case that a previous
        // liquidation has already liquidated the specified fCash asset. This liquidation can continue
        // to the next specified fCash asset.
        return 0;
    }

    /**
     * @notice Liquidates an account by converting their local currency collateral into cash and
     * eliminates any haircut value incurred by liquidity tokens or perpetual tokens. Requires no capital
     * on the part of the liquidator, this is pure arbitrage. It's highly unlikely that an account will
     * encounter this scenario but this method is here for completeness.
     */
    function liquidateLocalCurrency(
        uint localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime,
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        PortfolioState memory portfolio
    ) internal view returns (int) {
        int benefitRequired = factors.localETHRate.convertETHTo(factors.netETHValue.neg())
            .mul(ExchangeRate.MULTIPLIER_DECIMALS)
            .div(factors.localETHRate.buffer);
        int netLocalFromLiquidator;

        if (hasLiquidityTokens(portfolio.storedAssets, localCurrency)) {
            WithdrawFactors memory w;
            (w, benefitRequired) = withdrawLocalLiquidityTokens(portfolio, factors, blockTime, benefitRequired);
            netLocalFromLiquidator = w.totalIncentivePaid.neg();
            balanceState.netCashChange = w.totalCashClaim.sub(w.totalIncentivePaid);
        }

        if (factors.perpetualTokenValue > 0) {
            int perpetualTokensToLiquidate;
            {
                // This will not underflow, checked when saving parameters
                int haircutDiff = (
                    int(uint8(factors.perpetualTokenParameters[PerpetualToken.LIQUIDATION_HAIRCUT_PERCENTAGE])) -
                    int(uint8(factors.perpetualTokenParameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE]))
                ) * CashGroup.PERCENTAGE_DECIMALS;

                // benefitGained = perpTokensToLiquidate * (liquidatedPV - freeCollateralPV)
                // benefitGained = perpTokensToLiquidate * perpTokenPV * (liquidationHaircut - pvHaircut)
                // perpTokensToLiquidate = benefitGained / (perpTokenPV * (liquidationHaircut - pvHaircut))
                perpetualTokensToLiquidate = benefitRequired
                    .mul(TokenHandler.INTERNAL_TOKEN_PRECISION)
                    .div(factors.perpetualTokenValue.mul(haircutDiff).div(CashGroup.PERCENTAGE_DECIMALS));
            }
            
            perpetualTokensToLiquidate = calculateMaxLiquidationAmount(
                perpetualTokensToLiquidate,
                balanceState.storedPerpetualTokenBalance,
                int(maxPerpetualTokenLiquidation)
            );
            balanceState.netPerpetualTokenTransfer = perpetualTokensToLiquidate.neg();

            {
                // fullPerpTokenPV = haircutTokenPV / haircutPercentage
                // localFromLiquidator = tokensToLiquidate * fullPerpTokenPV * liquidationHaircut / totalBalance
                int localCashValue = perpetualTokensToLiquidate
                    .mul(int(uint8(factors.perpetualTokenParameters[PerpetualToken.LIQUIDATION_HAIRCUT_PERCENTAGE])))
                    .mul(factors.perpetualTokenValue)
                    .div(int(uint8(factors.perpetualTokenParameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE])))
                    .div(balanceState.storedPerpetualTokenBalance);

                balanceState.netCashChange = balanceState.netCashChange.add(localCashValue);
                netLocalFromLiquidator = netLocalFromLiquidator.add(localCashValue);
            }
        }

        return netLocalFromLiquidator;
    }

    function liquidateCollateralCurrency(
        uint128 maxCollateralLiquidation,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime,
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        PortfolioState memory portfolio
    ) internal view returns (int) {
        require(factors.localAvailable < 0, "No local debt");
        require(factors.collateralAvailable > 0, "No collateral");

        (
            int collateralToRaise,
            int localToPurchase,
            int liquidationDiscount
        ) = calculateCollateralToRaise(
            factors,
            int(maxCollateralLiquidation)
        );

        int collateralRemaining = collateralToRaise;
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

        if (collateralRemaining > 0 && hasLiquidityTokens(portfolio.storedAssets, balanceState.currencyId)) {
            int postWithdrawCollateral = withdrawCollateralLiquidityTokens(
                portfolio,
                factors,
                blockTime,
                collateralRemaining
            );
            balanceState.netCashChange = balanceState.netCashChange.add(collateralRemaining.sub(postWithdrawCollateral));
            collateralRemaining = postWithdrawCollateral;
        }

        if (collateralRemaining > 0 && factors.perpetualTokenValue > 0) {
            collateralRemaining = calculateCollateralPerpetualTokenTransfer(
                balanceState,
                factors,
                collateralRemaining,
                int(maxPerpetualTokenLiquidation)
            );
        }

        if (collateralRemaining > 0) {
            (/* collateralToRaise */, localToPurchase) = calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                collateralToRaise.sub(collateralRemaining),
                collateralToRaise.sub(collateralRemaining)
            );
        }

        return localToPurchase;
    }

    function calculateCollateralToRaise(
        LiquidationFactors memory factors,
        int maxCollateralLiquidation
    ) internal pure returns (int, int, int) {
        (int benefitRequired, int liquidationDiscount) = calculateCrossCurrencyBenefitAndDiscount(factors);
        int collateralToRaise;
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
            int denominator = factors.localETHRate.buffer
                .mul(ExchangeRate.MULTIPLIER_DECIMALS)
                .div(liquidationDiscount)
                .sub(factors.collateralETHRate.haircut);

            collateralToRaise = benefitRequired
                .mul(ExchangeRate.MULTIPLIER_DECIMALS)
                .div(denominator);
        }

        collateralToRaise = calculateMaxLiquidationAmount(
            collateralToRaise,
            factors.collateralAvailable,
            0 // will check userSpecifiedAmount below
        );

        int localToPurchase;
        (collateralToRaise, localToPurchase) = calculateLocalToPurchase(
            factors,
            liquidationDiscount,
            collateralToRaise,
            collateralToRaise
        );
        
        // Enforce the user specified max liquidation amount
        if (maxCollateralLiquidation > 0 && collateralToRaise > maxCollateralLiquidation) {
            collateralToRaise = maxCollateralLiquidation;

            (/* collateralToRaise */, localToPurchase) = calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                collateralToRaise,
                collateralToRaise
            );
        }

        return (collateralToRaise, localToPurchase, liquidationDiscount);
    }

    function calculateCollateralPerpetualTokenTransfer(
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        int collateralRemaining,
        int maxPerpetualTokenLiquidation
    ) internal pure returns (int) {
        // fullPerpTokenPV = haircutTokenPV / haircutPercentage
        // collateralToRaise = tokensToLiquidate * fullPerpTokenPV * liquidationHaircut / totalBalance
        // tokensToLiquidate = collateralToRaise * totalBalance / (fullPerpTokenPV * liquidationHaircut)
        int perpetualTokenLiquidationHaircut = int(uint8(factors.perpetualTokenParameters[PerpetualToken.LIQUIDATION_HAIRCUT_PERCENTAGE]));
        int perpetualTokenHaircut = int(uint8(factors.perpetualTokenParameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE]));
        int perpetualTokensToLiquidate = collateralRemaining 
            .mul(balanceState.storedPerpetualTokenBalance)
            .mul(perpetualTokenHaircut)
            .div(factors.perpetualTokenValue.mul(perpetualTokenLiquidationHaircut));

        if (maxPerpetualTokenLiquidation > 0 && perpetualTokensToLiquidate > maxPerpetualTokenLiquidation) {
            perpetualTokensToLiquidate = maxPerpetualTokenLiquidation;
        }

        if (perpetualTokensToLiquidate > balanceState.storedPerpetualTokenBalance) {
            perpetualTokensToLiquidate = balanceState.storedPerpetualTokenBalance;
        }

        balanceState.netPerpetualTokenTransfer = perpetualTokensToLiquidate.neg();
        collateralRemaining = collateralRemaining.subNoNeg(
            // collateralToRaise = (perpetualTokenToLiquidate * perpTokenPV * liquidateHaircutPercentage) / perpetualTokenBalance
            perpetualTokensToLiquidate
                .mul(factors.perpetualTokenValue)
                .mul(perpetualTokenLiquidationHaircut)
                .div(perpetualTokenHaircut)
                .div(balanceState.storedPerpetualTokenBalance)
        );

        return collateralRemaining;
    }

    struct fCashContext {
        AccountStorage accountContext;
        LiquidationFactors factors;
        PortfolioState portfolio;
        int benefitRequired;
        int localToPurchase;
        int liquidationDiscount;
        int[] fCashNotionalTransfers;
    }

    function liquidatefCashLocal(
        address liquidateAccount,
        uint localCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint blockTime
    ) internal view {
        if (c.factors.localAvailable > 0) {
            // If local available is positive then we can bring it down to zero
            c.benefitRequired = c.factors.localETHRate.convertETHTo(c.factors.netETHValue.neg())
                .mul(ExchangeRate.MULTIPLIER_DECIMALS)
                .div(c.factors.localETHRate.haircut);
        } else {
            // If local available is negative then we can bring it up to zero
            c.benefitRequired = c.factors.localAvailable.neg()
                .mul(ExchangeRate.MULTIPLIER_DECIMALS)
                .div(c.factors.localETHRate.buffer);
        }

        for (uint i; i < fCashMaturities.length; i++) {
            int notional = getfCashNotional(
                liquidateAccount,
                c,
                localCurrency,
                fCashMaturities[i]
            );
            if (notional == 0) continue;

            // We know that liquidation discount > risk adjusted discount because they are required to
            // be this way when setting cash group variables.
            (int riskAdjustedDiscountFactor, int liquidationDiscountFactor) = calculatefCashDiscounts(
                c.factors,
                fCashMaturities[i],
                blockTime
            );

            // The benefit to the liquidated account is the difference between the liquidation discount factor
            // and the risk adjusted discount factor:
            // localCurrencyBenefit = fCash * (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            // fCash = localCurrencyBeneift / (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            c.fCashNotionalTransfers[i] = c.benefitRequired
                .mul(Market.RATE_PRECISION)
                .div(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor));

            c.fCashNotionalTransfers[i] = calculateMaxLiquidationAmount(
                c.fCashNotionalTransfers[i],
                notional,
                int(maxfCashLiquidateAmounts[i])
            );

            // Calculate the amount of local currency required from the liquidator
            c.localToPurchase = c.localToPurchase.add(
                c.fCashNotionalTransfers[i]
                    .mul(liquidationDiscountFactor)
                    .div(Market.RATE_PRECISION)
            );

            // Deduct the total benefit gained from liquidating this fCash position
            c.benefitRequired = c.benefitRequired.sub(
                c.fCashNotionalTransfers[i]
                    .mul(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor))
                    .div(Market.RATE_PRECISION)
            );

            if (c.benefitRequired <= 0) break;
        }
    }

    function calculateCrossCurrencyfCashToLiquidate(
        fCashContext memory c,
        uint maturity,
        uint blockTime,
        int maxfCashLiquidateAmount,
        int notional
    ) private view returns (int) {
        (int riskAdjustedDiscountFactor, int liquidationDiscountFactor) = calculatefCashDiscounts(
            c.factors,
            maturity,
            blockTime
        );

        // collateralPurchased = fCashToLiquidate * fCashDiscountFactor
        // (see: calculateCollateralToRaise)
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
        int benefitMultiplier; 
        {
            int termTwo = (
                c.factors.localETHRate.buffer
                    .mul(CashGroup.PERCENTAGE_DECIMALS)
                    .div(c.liquidationDiscount)
                ).sub(c.factors.collateralETHRate.haircut);
            termTwo = liquidationDiscountFactor.mul(termTwo).div(CashGroup.PERCENTAGE_DECIMALS);
            int termOne = liquidationDiscountFactor.sub(riskAdjustedDiscountFactor);
            benefitMultiplier = termOne.add(termTwo);
        }

        int fCashToLiquidate = c.benefitRequired.mul(Market.RATE_PRECISION).div(benefitMultiplier);
        fCashToLiquidate = calculateMaxLiquidationAmount(
            fCashToLiquidate,
            notional,
            maxfCashLiquidateAmount
        );

        // Ensures that local available does not go above zero and collateral available does not go below zero
        int localToPurchase;
        (fCashToLiquidate, localToPurchase) = limitPurchaseByAvailableAmounts(
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
        int benefitGained = fCashToLiquidate.mul(benefitMultiplier).div(Market.RATE_PRECISION);

        c.benefitRequired = c.benefitRequired.sub(benefitGained);
        c.localToPurchase = c.localToPurchase.add(localToPurchase);

        return fCashToLiquidate;
    }

    function limitPurchaseByAvailableAmounts(
        fCashContext memory c,
        int liquidationDiscountFactor,
        int riskAdjustedDiscountFactor,
        int fCashToLiquidate
    ) private pure returns (int, int) {
        // The collateral value of the fCash is discounted back to PV given the liquidation discount factor,
        // this is the discounted value that the liquidator will purchase it at.
        int fCashLiquidationPV = fCashToLiquidate.mul(liquidationDiscountFactor).div(Market.RATE_PRECISION);
        int fCashBenefit = fCashToLiquidate
            .mul(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor))
            .div(Market.RATE_PRECISION);

        // Ensures that collateralAvailable does not go below zero
        if (fCashLiquidationPV > c.factors.collateralAvailable.add(fCashBenefit)) {
            fCashToLiquidate = c.factors.collateralAvailable
                .mul(Market.RATE_PRECISION)
                .div(liquidationDiscountFactor);
        }

        int localToPurchase;
        (fCashToLiquidate, localToPurchase) = calculateLocalToPurchase(
            c.factors,
            c.liquidationDiscount,
            fCashLiquidationPV,
            fCashToLiquidate
        );

        // As we liquidate here the local available and collateral available will change. Update values accordingly so
        // that the limits will be hit on subsequent iterations.
        c.factors.collateralAvailable = c.factors.collateralAvailable.sub(
            fCashToLiquidate.mul(riskAdjustedDiscountFactor).div(Market.RATE_PRECISION)
        );
        // Local available does not have any buffers applied to it
        c.factors.localAvailable = c.factors.localAvailable.add(localToPurchase);

        return (fCashToLiquidate, localToPurchase);
    }

    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint collateralCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint blockTime
    ) internal {
        require(c.factors.localAvailable < 0, "No local debt");
        require(c.factors.collateralAvailable > 0, "No collateral assets");

        c.fCashNotionalTransfers = new int[](fCashMaturities.length);
        (c.benefitRequired, c.liquidationDiscount) = calculateCrossCurrencyBenefitAndDiscount(c.factors);

        for (uint i; i < fCashMaturities.length; i++) {
            int notional = getfCashNotional(
                liquidateAccount,
                c,
                collateralCurrency,
                fCashMaturities[i]
            );
            if (notional == 0) continue;

            c.fCashNotionalTransfers[i] = calculateCrossCurrencyfCashToLiquidate(
                c,
                fCashMaturities[i],
                blockTime,
                int(maxfCashLiquidateAmounts[i]),
                notional
            );

            if (c.benefitRequired <= 0 || c.factors.collateralAvailable <= 0) break;
        }
    }

    struct WithdrawFactors {
        int netCashIncrease;
        int fCash;
        int assetCash;
        int totalIncentivePaid;
        int totalCashClaim;
        int incentivePaid;
    }

    /**
     * @notice Withdraws liquidity tokens from a portfolio. Assumes that no trading will occur during
     * liquidation so portfolioState.newAssets.length == 0. If liquidity tokens are settled they will
     * not create new assets, the net fCash asset will replace the liquidity token asset.
     */
    function withdrawLocalLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint blockTime,
        int assetAmountRemaining
    ) internal view returns (WithdrawFactors memory, int) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        // Do this to deal with stack issues
        WithdrawFactors memory w;

        // NOTE: even if stored assets have been modified in memory as a result of the Asset.getRiskAdjustedPortfolioValue
        // method getting the haircut value will still work here because we do not reference the fCash value.
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (!AssetHandler.isLiquidityToken(asset.assetType) || asset.currencyId != factors.cashGroup.currencyId) continue;
            
            MarketParameters memory market = factors.cashGroup.getMarket(factors.markets, asset.assetType - 1, blockTime, true);

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
                int haircut = int(factors.cashGroup.getLiquidityHaircut(asset.assetType));
                w.netCashIncrease = w.assetCash
                    .mul(CashGroup.PERCENTAGE_DECIMALS.sub(haircut))
                    .div(CashGroup.PERCENTAGE_DECIMALS);
            }
            w.incentivePaid = w.netCashIncrease
                .mul(TOKEN_REPO_INCENTIVE_PERCENT)
                .div(CashGroup.PERCENTAGE_DECIMALS);

            // (netCashToAccount <= assetAmountRemaining)
            if (w.netCashIncrease.subNoNeg(w.incentivePaid) <= assetAmountRemaining) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // assetAmountRemaining = assetAmountRemaining - netCashToAccount
                // netCashToAccount = netCashIncrease - incentivePaid
                // overflow checked above
                assetAmountRemaining = assetAmountRemaining - w.netCashIncrease.sub(w.incentivePaid);
            } else {
                // incentivePaid
                w.incentivePaid = assetAmountRemaining.mul(TOKEN_REPO_INCENTIVE_PERCENT).div(CashGroup.PERCENTAGE_DECIMALS);

                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                int tokensToRemove = asset.notional.mul(assetAmountRemaining).div(w.netCashIncrease);

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
                AssetHandler.FCASH_ASSET_TYPE,
                w.fCash,
                false
            );

            if (assetAmountRemaining == 0) break;
        }

        return (w, assetAmountRemaining);
    }

    /**
     * @dev Similar to withdraw liquidity tokens, except there is no incentive paid and we do not worry about
     * haircut amounts, we simply withdraw as much collateral as needed.
     */
    function withdrawCollateralLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint blockTime,
        int collateralToWithdraw
    ) internal view returns (int) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (!AssetHandler.isLiquidityToken(asset.assetType) || asset.currencyId != factors.cashGroup.currencyId) continue;
            
            MarketParameters memory market = factors.cashGroup.getMarket(factors.markets, asset.assetType - 1, blockTime, true);
            (int cashClaim, int fCashClaim) = asset.getCashClaims(market);

            if (cashClaim <= collateralToWithdraw) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // overflow checked above
                collateralToWithdraw = collateralToWithdraw - cashClaim;
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // notional * collateralToWithdraw / cashClaim
                int tokensToRemove = asset.notional.mul(collateralToWithdraw).div(cashClaim);
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
                AssetHandler.FCASH_ASSET_TYPE,
                fCashClaim,
                false
            );

            if (collateralToWithdraw == 0) return 0;
        }

        return collateralToWithdraw;
    }

}
