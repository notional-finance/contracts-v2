// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    ETHRate,
    BalanceState,
    AccountContext,
    LiquidationFactors
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {LiquidationHelpers} from "./LiquidationHelpers.sol";
import {AccountContextHandler} from "../AccountContextHandler.sol";
import {ExchangeRate} from "../valuation/ExchangeRate.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";

library LiquidateCurrency {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using PrimeRateLib for PrimeRate;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

    /// @notice Liquidates an account by converting their local currency collateral into cash and
    /// eliminates any haircut value incurred by liquidity tokens or nTokens. Requires no capital
    /// on the part of the liquidator, this is pure arbitrage. It's highly unlikely that an account will
    /// encounter this scenario but this method is here for completeness.
    function liquidateLocalCurrency(
        uint96 maxNTokenLiquidation,
        BalanceState memory balanceState,
        LiquidationFactors memory factors
    ) internal pure returns (int256 netPrimeCashFromLiquidator) {
        // If local asset available == 0 then there is nothing that this liquidation can do.
        require(factors.localPrimeAvailable != 0);
        int256 primeBenefitRequired;
        {
            // Local currency liquidation adds free collateral value back to an account by trading nTokens or
            // liquidity tokens back to cash in the same local currency. Local asset available may be
            // either positive or negative when we enter this method.
            //
            // If local asset available is positive then there is a debt in a different currency, in this
            // case we are not paying off any debt in the other currency. We are only adding free collateral in the
            // form of a reduced haircut on nTokens or liquidity tokens. It may be possible to do a subsequent
            // collateral currency liquidation to trade local cash for the collateral cash to actually pay down
            // the debt. If that happens, the account would gain the benefit of removing the haircut on
            // the local currency and also removing the buffer on the negative collateral debt.
            //
            // If localPrimeAvailable is negative then this will reduce free collateral by trading
            // nTokens or liquidity tokens back to cash in this currency.

            primeBenefitRequired =
                factors.localPrimeRate.convertFromUnderlying(
                    LiquidationHelpers.calculateLocalLiquidationUnderlyingRequired(
                        factors.localPrimeAvailable,
                        factors.netETHValue,
                        factors.localETHRate
                    )
                );
        }

        if (factors.nTokenHaircutPrimeValue > 0) {
            int256 nTokensToLiquidate;
            {
                // This check is applied when saving parameters but we double check it here.
                require(
                    uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]) >
                    uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])
                ); // dev: haircut percentage underflow
                // This will calculate how much nTokens to liquidate given the "primeBenefitRequired" calculated above.
                // We are supplied with the nTokenHaircutPrimeValue, this is calculated in the formula below. This value
                // is calculated in FreeCollateral._getNTokenHaircutPrimePV and is equal to:
                // nTokenHaircutPrimeValue = (tokenBalance * nTokenPrimePV * PV_HAIRCUT_PERCENTAGE) / totalSupply
                // where:
                //      nTokenPrimePV: this is the non-risk adjusted (no haircut applied) value of all nToken holdings
                //      totalSupply: the total supply of nTokens
                //      tokenBalance: the balance of the liquidated account's nTokens
                //      PV_HAIRCUT_PERCENTAGE: the discount to the nTokenPrimePV applied during risk adjustment
                //
                // Benefit gained is the local asset cash denominated amount of free collateral benefit given to the liquidated
                // account as a result of purchasing nTokens in exchange for cash in the same currency. The amount of benefit gained
                // is equal to the removal of the haircut on the nTokenValue minus the discount given to the liquidator.
                //
                // benefitGained = nTokensToLiquidate * (nTokenLiquidatedValue - nTokenHaircutPrimeValue) / tokenBalance
                // where:
                //   nTokenHaircutPrimeValue = (tokenBalance * nTokenPrimePV * PV_HAIRCUT_PERCENTAGE) / totalSupply
                //   nTokenLiquidatedValue = (tokenBalance * nTokenPrimePV * LIQUIDATION_HAIRCUT_PERCENTAGE) / totalSupply
                // NOTE: nTokenLiquidatedValue > nTokenHaircutPrimeValue because we require that:
                //        LIQUIDATION_HAIRCUT_PERCENTAGE > PV_HAIRCUT_PERCENTAGE
                //
                // nTokenHaircutPrimeValue - nTokenLiquidatedValue =
                //    (tokenBalance * nTokenPrimePV) / totalSupply * (LIQUIDATION_HAIRCUT_PERCENTAGE - PV_HAIRCUT_PERCENTAGE)
                //
                // From above:
                //    (tokenBalance * nTokenPrimePV) / totalSupply = nTokenHaircutPrimeValue / PV_HAIRCUT_PERCENTAGE
                //
                // Therefore:
                // nTokenHaircutPrimeValue - nTokenLiquidatedValue =
                //    nTokenHaircutPrimeValue * (LIQUIDATION_HAIRCUT_PERCENTAGE - PV_HAIRCUT_PERCENTAGE) / PV_HAIRCUT_PERCENTAGE
                //
                // Finally:
                // benefitGained = nTokensToLiquidate * (nTokenLiquidatedValue - nTokenHaircutPrimeValue) / tokenBalance
                // nTokensToLiquidate = tokenBalance * benefitGained * PV_HAIRCUT / 
                //          (nTokenHaircutPrimeValue * (LIQUIDATION_HAIRCUT - PV_HAIRCUT_PERCENTAGE))
                //
                int256 haircutDiff =
                    (uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]) -
                            uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]));

                nTokensToLiquidate = primeBenefitRequired
                    .mul(balanceState.storedNTokenBalance)
                    .mul(int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])))
                    .div(factors.nTokenHaircutPrimeValue.mul(haircutDiff));
            }

            nTokensToLiquidate = LiquidationHelpers.calculateLiquidationAmount(
                nTokensToLiquidate,
                balanceState.storedNTokenBalance,
                maxNTokenLiquidation
            );
            balanceState.netNTokenTransfer = nTokensToLiquidate.neg();

            {
                // Calculates how much the liquidator must pay for the nTokens they are liquidating. Defined as:
                // nTokenHaircutPrimeValue = (tokenBalance * nTokenPrimePV * PV_HAIRCUT_PERCENTAGE) / totalSupply
                // nTokenLiquidationPrice = (tokensToLiquidate * nTokenPrimePV * LIQUIDATION_HAIRCUT) / totalSupply
                //
                // Combining the two formulas:
                // nTokenHaircutPrimeValue / (tokenBalance * PV_HAIRCUT_PERCENTAGE) = (nTokenPrimePV / totalSupply)
                // nTokenLiquidationPrice = (tokensToLiquidate * LIQUIDATION_HAIRCUT * nTokenHaircutPrimeValue) / 
                //      (tokenBalance * PV_HAIRCUT_PERCENTAGE)
                // prettier-ignore
                int256 localPrimeCash =
                    nTokensToLiquidate
                        .mul(int256(uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE])))
                        .mul(factors.nTokenHaircutPrimeValue)
                        .div(int256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])))
                        .div(balanceState.storedNTokenBalance);

                balanceState.netCashChange = balanceState.netCashChange.add(localPrimeCash);
                netPrimeCashFromLiquidator = netPrimeCashFromLiquidator.add(localPrimeCash);
            }
        }
    }

    /// @notice Liquidates collateral in the form of cash, liquidity token cash claims, or nTokens in that
    /// liquidation preference.
    function liquidateCollateralCurrency(
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        BalanceState memory balanceState,
        LiquidationFactors memory factors
    ) internal pure returns (int256) {
        require(factors.localPrimeAvailable < 0, "No local debt");
        require(factors.collateralAssetAvailable > 0, "No collateral");

        (
            int256 requiredCollateralPrimeCash,
            int256 localPrimeCashFromLiquidator
        ) = _calculateCollateralToRaise(factors, maxCollateralLiquidation);

        int256 collateralPrimeRemaining = requiredCollateralPrimeCash;
        // First in liquidation preference is the cash balance. Take as much cash as allowed.
        if (balanceState.storedCashBalance > 0) {
            if (balanceState.storedCashBalance >= collateralPrimeRemaining) {
                balanceState.netCashChange = collateralPrimeRemaining.neg();
                collateralPrimeRemaining = 0;
            } else {
                // Sell off all cash balance and calculate remaining collateral
                balanceState.netCashChange = balanceState.storedCashBalance.neg();
                // Collateral prime remaining cannot be negative
                collateralPrimeRemaining = collateralPrimeRemaining.subNoNeg(
                    balanceState.storedCashBalance
                );
            }
        }

        if (collateralPrimeRemaining > 0 && factors.nTokenHaircutPrimeValue > 0) {
            collateralPrimeRemaining = _calculateCollateralNTokenTransfer(
                balanceState,
                factors,
                collateralPrimeRemaining,
                maxNTokenLiquidation
            );
        }

        if (collateralPrimeRemaining > 0) {
            // Any remaining collateral required will be left on the account as a prime cash debt
            // position. This effectively takes all of the cross currency risk off of the account
            // and turns it into local currency interest rate risk. The account will be eligible for
            // local currency liquidation against nTokens or fCash held in the collateral currency.
            // The reasoning for this is that cross currency risk poses volatile exogenous risk
            // to the system, whereas local currency interest rate is internal to the system and capped
            // at by the tradable interest rate range and duration of the fCash and nToken assets.
            balanceState.netCashChange = balanceState.netCashChange.sub(collateralPrimeRemaining);
        }

        return localPrimeCashFromLiquidator;
    }

    /// @dev Calculates anticipated collateral to raise, enforcing some limits. Actual transfers may be lower due
    /// to limits on the nToken transfer
    function _calculateCollateralToRaise(
        LiquidationFactors memory factors,
        int256 maxCollateralLiquidation
    ) private pure returns (
        int256 requiredCollateralPrimeCash,
        int256 localPrimeCashFromLiquidator
    ) {
        (
            int256 collateralDenominatedFC,
            int256 liquidationDiscount
        ) = LiquidationHelpers.calculateCrossCurrencyFactors(factors);

        {
            // Solve for the amount of collateral to sell to recoup the free collateral shortfall,
            // accounting for the buffer to local currency debt and the haircut on collateral. The
            // total amount of shortfall that we want to recover is the netETHValue (the total negative
            // free collateral).
            //
            // netETHValue.neg() = localPurchased * localBuffer * exRateLocalToETH -
            //      collateralToSell * collateralHaircut * exRateCollateralToETH
            //
            // We can multiply both sides by 1/exRateCollateralToETH:
            //
            // collateralDenominatedFC = localPurchased * localBuffer * exRateLocalToCollateral -
            //      collateralToSell * collateralHaircut
            //
            // where localPurchased is defined as:
            // localPurchased = collateralToSell / (exRateLocalToCollateral * liquidationDiscount)
            //
            // collateralDenominatedFC = [
            //    (collateralToSell / (exRateLocalToCollateral * liquidationDiscount)) * localBuffer * exRateLocalToCollateral -
            //    collateralToSell * collateralHaircut
            // ]
            // collateralDenominatedFC =
            //    (collateralToSell * localBuffer) / liquidationDiscount - collateralToSell * collateralHaircut
            // collateralDenominatedFC = collateralToSell * ((localBuffer / liquidationDiscount) - collateralHaircut)
            // collateralToSell = collateralDenominatedFC / ((localBuffer / liquidationDiscount) - collateralHaircut)
            int256 denominator =
                factors.localETHRate.buffer
                    .mul(Constants.PERCENTAGE_DECIMALS)
                    .div(liquidationDiscount)
                    .sub(factors.collateralETHRate.haircut);

            requiredCollateralPrimeCash = collateralDenominatedFC
                .mul(Constants.PERCENTAGE_DECIMALS)
                .div(denominator);
        }

        requiredCollateralPrimeCash = LiquidationHelpers.calculateLiquidationAmount(
            requiredCollateralPrimeCash,
            factors.collateralAssetAvailable,
            maxCollateralLiquidation
        );

        // In this case the collateral asset present value and the collateral asset balance to sell are the same
        // value since cash is always equal to present value. That is why the last two parameters in calculateLocalToPurchase
        // are the same value.
        int256 collateralUnderlyingPresentValue =
            factors.collateralCashGroup.primeRate.convertToUnderlying(requiredCollateralPrimeCash);

        (requiredCollateralPrimeCash, localPrimeCashFromLiquidator) = LiquidationHelpers.calculateLocalToPurchase(
            factors,
            liquidationDiscount,
            collateralUnderlyingPresentValue,
            requiredCollateralPrimeCash
        );
    }

    /// @dev Calculates the nToken transfer.
    function _calculateCollateralNTokenTransfer(
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        int256 collateralPrimeRemaining,
        int256 maxNTokenLiquidation
    ) internal pure returns (int256) {
        // See longer comment in `liquidateLocalCurrency`, the main difference here is that we know how much
        // collateral we want to raise instead of calculating a "benefitGained" difference in a single currency.
        // collateralToRaise = (tokensToLiquidate * nTokenPrimePV * LIQUIDATION_HAIRCUT) / totalSupply
        // where:
        //    nTokenHaircutPrimeValue = (tokenBalance * nTokenPrimePV * PV_HAIRCUT_PERCENTAGE) / totalSupply
        //    nTokenPrimePV = (nTokenHaircutPrimeValue * totalSupply) / (PV_HAIRCUT_PERCENTAGE * tokenBalance)

        // tokensToLiquidate = (collateralToRaise * totalSupply) / (nTokenPrimePV * LIQUIDATION_HAIRCUT)
        // tokensToLiquidate = (collateralToRaise * tokenBalance * PV_HAIRCUT) /
        //      (nTokenHaircutPrimeValue * LIQUIDATION_HAIRCUT)

        int256 nTokenLiquidationHaircut =
            uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]);
        int256 nTokenHaircut =
            uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]);
        int256 nTokensToLiquidate =
            collateralPrimeRemaining
                .mul(balanceState.storedNTokenBalance)
                .mul(nTokenHaircut)
                .div(factors.nTokenHaircutPrimeValue.mul(nTokenLiquidationHaircut));

        if (maxNTokenLiquidation > 0 && nTokensToLiquidate > maxNTokenLiquidation) {
            nTokensToLiquidate = maxNTokenLiquidation;
        }

        if (nTokensToLiquidate > balanceState.storedNTokenBalance) {
            nTokensToLiquidate = balanceState.storedNTokenBalance;
        }

        balanceState.netNTokenTransfer = nTokensToLiquidate.neg();
        // NOTE: it's possible that this results in > DEFAULT_LIQUIDATION_PORTION in PV terms. However, it will not be more than
        // the liquidateHaircutPercentage which will be set to a nominal amount. Since DEFAULT_LIQUIDATION_PORTION is arbitrary we
        // don't put too much emphasis on this and allow it to occur.
        // Formula here:
        // collateralToRaise = (tokensToLiquidate * nTokenHaircutPrimeValue * LIQUIDATION_HAIRCUT) / (PV_HAIRCUT_PERCENTAGE * tokenBalance)
        collateralPrimeRemaining = collateralPrimeRemaining.subNoNeg(
            nTokensToLiquidate
                .mul(factors.nTokenHaircutPrimeValue)
                .mul(nTokenLiquidationHaircut)
                .div(nTokenHaircut)
                .div(balanceState.storedNTokenBalance)
        );

        return collateralPrimeRemaining;
    }
}
