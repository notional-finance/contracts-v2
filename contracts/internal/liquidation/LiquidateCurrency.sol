// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "./LiquidationHelpers.sol";
import "../AccountContextHandler.sol";
import "../valuation/ExchangeRate.sol";
import "../markets/CashGroup.sol";
import "../markets/AssetRate.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "../balances/BalanceHandler.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

library LiquidateCurrency {
    using UserDefinedType for IA;
    using UserDefinedType for IU;
    using UserDefinedType for LT;
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;

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
    ) internal returns (IA netAssetCashFromLiquidator) {
        // If local asset available == 0 then there is nothing that this liquidation can do.
        require(factors.localAssetAvailable.isNotZero());
        IA assetBenefitRequired;
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
            // If localAssetAvailable is negative then this will reduce free collateral by trading
            // nTokens or liquidity tokens back to cash in this currency.

            assetBenefitRequired =
                factors.localAssetRate.convertFromUnderlying(
                    LiquidationHelpers.calculateLocalLiquidationUnderlyingRequired(
                        factors.localAssetAvailable,
                        factors.netETHValue,
                        factors.localETHRate
                    )
                );
        }

        {
            WithdrawFactors memory w;
            // Will check if the account actually has liquidity tokens
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

        if (factors.nTokenHaircutAssetValue.isPosNotZero()) {
            int256 nTokensToLiquidate;
            {
                // This check is applied when saving parameters but we double check it here.
                require(
                    uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]) >
                    uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])
                ); // dev: haircut percentage underflow
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
                // nTokensToLiquidate = tokenBalance * benefitGained * PV_HAIRCUT / 
                //          (nTokenHaircutAssetValue * (LIQUIDATION_HAIRCUT - PV_HAIRCUT_PERCENTAGE))
                //
                int256 haircutDiff = int256(uint256(
                    (uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]) -
                            uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]))
                ));

                nTokensToLiquidate = IA.unwrap(assetBenefitRequired)
                    .mul(balanceState.storedNTokenBalance)
                    .mul(int256(uint256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]))))
                    .div(IA.unwrap(factors.nTokenHaircutAssetValue).mul(haircutDiff));
            }

            nTokensToLiquidate = LiquidationHelpers.calculateLiquidationAmount(
                nTokensToLiquidate,
                balanceState.storedNTokenBalance,
                int256(uint256(maxNTokenLiquidation))
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
                // prettier-ignore
                IA localAssetCash = IA.wrap(
                    nTokensToLiquidate
                        .mul(int256(uint256(uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE]))))
                        .mul(IA.unwrap(factors.nTokenHaircutAssetValue))
                        .div(int256(uint256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE]))))
                        .div(balanceState.storedNTokenBalance)
                );

                balanceState.netCashChange = balanceState.netCashChange.add(localAssetCash);
                netAssetCashFromLiquidator = netAssetCashFromLiquidator.add(localAssetCash);
            }
        }
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
    ) internal returns (IA) {
        require(factors.localAssetAvailable.isNegNotZero(), "No local debt");
        require(factors.collateralAssetAvailable.isPosNotZero(), "No collateral");

        (
            IA requiredCollateralAssetCash,
            IA localAssetCashFromLiquidator,
            int256 liquidationDiscount
        ) = _calculateCollateralToRaise(factors, int256(uint256(maxCollateralLiquidation)));

        IA collateralAssetRemaining = requiredCollateralAssetCash;
        // First in liquidation preference is the cash balance. Take as much cash as allowed.
        if (balanceState.storedCashBalance.isPosNotZero()) {
            if (balanceState.storedCashBalance.gt(collateralAssetRemaining)) {
                balanceState.netCashChange = collateralAssetRemaining.neg();
                collateralAssetRemaining = IA.wrap(0);
            } else {
                // Sell off all cash balance and calculate remaining collateral
                balanceState.netCashChange = balanceState.storedCashBalance.neg();
                // Collateral asset remaining cannot be negative
                collateralAssetRemaining = collateralAssetRemaining.subNoNeg(
                    balanceState.storedCashBalance
                );
            }
        }

        if (collateralAssetRemaining.isPosNotZero()) {
            // Will check inside if the account actually has liquidity token
            IA newCollateralAssetRemaining =
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
            balanceState.netAssetTransferInternalPrecision = collateralAssetRemaining.sub(
                newCollateralAssetRemaining
            );
            collateralAssetRemaining = newCollateralAssetRemaining;
        }

        if (collateralAssetRemaining.isPosNotZero() && factors.nTokenHaircutAssetValue.isPosNotZero()) {
            collateralAssetRemaining = _calculateCollateralNTokenTransfer(
                balanceState,
                factors,
                collateralAssetRemaining,
                int256(uint256(maxNTokenLiquidation))
            );
        }

        if (collateralAssetRemaining.isPosNotZero()) {
            // If there is any collateral asset remaining then recalculate the localAssetCashFromLiquidator.
            IA actualCollateralAssetSold = requiredCollateralAssetCash.sub(collateralAssetRemaining);
            IU collateralUnderlyingPresentValue =
                factors.collateralCashGroup.assetRate.convertToUnderlying(actualCollateralAssetSold);
            // prettier-ignore
            (
                /* collateralToRaise */,
                localAssetCashFromLiquidator
            ) = LiquidationHelpers.calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                collateralUnderlyingPresentValue,
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
            IA requiredCollateralAssetCash,
            IA localAssetCashFromLiquidator,
            int256 liquidationDiscount
        )
    {
        IA collateralDenominatedFC;
        (collateralDenominatedFC, liquidationDiscount) = LiquidationHelpers.calculateCrossCurrencyFactors(factors);
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

            requiredCollateralAssetCash = collateralDenominatedFC
                .scale(Constants.PERCENTAGE_DECIMALS, denominator);
        }

        requiredCollateralAssetCash = IA.wrap(LiquidationHelpers.calculateLiquidationAmount(
            IA.unwrap(requiredCollateralAssetCash),
            IA.unwrap(factors.collateralAssetAvailable),
            maxCollateralLiquidation
        ));

        // In this case the collateral asset present value and the collateral asset balance to sell are the same
        // value since cash is always equal to present value. That is why the last two parameters in calculateLocalToPurchase
        // are the same value.
        IU collateralUnderlyingPresentValue =
            factors.collateralCashGroup.assetRate.convertToUnderlying(requiredCollateralAssetCash);
        (requiredCollateralAssetCash, localAssetCashFromLiquidator) = LiquidationHelpers
            .calculateLocalToPurchase(
                factors,
                liquidationDiscount,
                collateralUnderlyingPresentValue,
                requiredCollateralAssetCash
            );

        return (requiredCollateralAssetCash, localAssetCashFromLiquidator, liquidationDiscount);
    }

    /// @dev Calculates the nToken transfer.
    function _calculateCollateralNTokenTransfer(
        BalanceState memory balanceState,
        LiquidationFactors memory factors,
        IA collateralAssetRemaining,
        int256 maxNTokenLiquidation
    ) internal pure returns (IA) {
        // See longer comment in `liquidateLocalCurrency`, the main difference here is that we know how much
        // collateral we want to raise instead of calculating a "benefitGained" difference in a single currency.
        // collateralToRaise = (tokensToLiquidate * nTokenAssetPV * LIQUIDATION_HAIRCUT) / totalSupply
        // where:
        //    nTokenHaircutAssetValue = (tokenBalance * nTokenAssetPV * PV_HAIRCUT_PERCENTAGE) / totalSupply
        //    nTokenAssetPV = (nTokenHaircutAssetValue * totalSupply) / (PV_HAIRCUT_PERCENTAGE * tokenBalance)

        // tokensToLiquidate = (collateralToRaise * totalSupply) / (nTokenAssetPV * LIQUIDATION_HAIRCUT)
        // tokensToLiquidate = (collateralToRaise * tokenBalance * PV_HAIRCUT) /
        //      (nTokenHaircutAssetValue * LIQUIDATION_HAIRCUT)

        int256 nTokenLiquidationHaircut =
            int256(uint256(uint8(factors.nTokenParameters[Constants.LIQUIDATION_HAIRCUT_PERCENTAGE])));
        int256 nTokenHaircut =
            int256(uint256(uint8(factors.nTokenParameters[Constants.PV_HAIRCUT_PERCENTAGE])));
        int256 nTokensToLiquidate =
            IA.unwrap(collateralAssetRemaining)
                .mul(balanceState.storedNTokenBalance)
                .mul(nTokenHaircut)
                .div(IA.unwrap(factors.nTokenHaircutAssetValue).mul(nTokenLiquidationHaircut));

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
        // collateralToRaise = (tokensToLiquidate * nTokenHaircutAssetValue * LIQUIDATION_HAIRCUT) / (PV_HAIRCUT_PERCENTAGE * tokenBalance)
        collateralAssetRemaining = collateralAssetRemaining.subNoNeg(
            IA.wrap(nTokensToLiquidate
                .mul(IA.unwrap(factors.nTokenHaircutAssetValue))
                .mul(nTokenLiquidationHaircut)
                .div(nTokenHaircut)
                .div(balanceState.storedNTokenBalance))
        );

        return collateralAssetRemaining;
    }

    struct WithdrawFactors {
        IA netCashIncrease;
        IU fCash;
        IA assetCash;
        IA totalIncentivePaid;
        IA totalCashClaim;
        IA incentivePaid;
    }

    /// @notice Withdraws local liquidity tokens from a portfolio and pays an incentive to the liquidator.
    /// @return withdraw factors to update liquidator and liquidated cash balances, the asset amount remaining
    function _withdrawLocalLiquidityTokens(
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        uint256 blockTime,
        IA assetAmountRemaining
    ) internal returns (WithdrawFactors memory, IA) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        MarketParameters memory market;
        // Do this to deal with stack issues
        WithdrawFactors memory w;

        // Loop through the stored assets in reverse order. This ensures that we withdraw the longest dated
        // liquidity tokens first. Longer dated liquidity tokens will generally have larger haircuts and therefore
        // provide more benefit when withdrawn.
        for (uint256 i = portfolioState.storedAssets.length; (i--) > 0;) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            // NOTE: during local liquidation, if the account has assets in local currency then
            // collateral cash group will be set to the local cash group
            if (!_isValidWithdrawToken(asset, factors.collateralCashGroup.currencyId)) continue;

            (w.assetCash, w.fCash) = _loadMarketAndGetClaims(
                asset,
                factors.collateralCashGroup,
                market,
                blockTime
            );

            (w.netCashIncrease, w.incentivePaid) = _calculateNetCashIncreaseAndIncentivePaid(
                factors, w.assetCash, asset.assetType);

            // (netCashToAccount <= assetAmountRemaining)
            if (w.netCashIncrease.subNoNeg(w.incentivePaid).lte(assetAmountRemaining)) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                if (!factors.isCalculation) market.removeLiquidity(LT.wrap(asset.notional));

                // assetAmountRemaining = assetAmountRemaining - netCashToAccount
                // netCashToAccount = netCashIncrease - incentivePaid
                // overflow checked above
                assetAmountRemaining = assetAmountRemaining.sub(w.netCashIncrease.sub(w.incentivePaid));
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                LT tokensToRemove = LT.wrap(asset.notional).scale(
                    IA.unwrap(assetAmountRemaining),
                    IA.unwrap(w.netCashIncrease.subNoNeg(w.incentivePaid))
                );

                if (!factors.isCalculation) {
                    (w.assetCash, w.fCash) = market.removeLiquidity(tokensToRemove);
                } else {
                    w.assetCash = market.totalAssetCash.scale(LT.unwrap(tokensToRemove), LT.unwrap(market.totalLiquidity));
                    w.fCash = market.totalfCash.scale(LT.unwrap(tokensToRemove), LT.unwrap(market.totalLiquidity));
                }
                // Recalculate net cash increase and incentive paid. w.assetCash is different because we partially
                // remove asset cash
                (w.netCashIncrease, w.incentivePaid) = _calculateNetCashIncreaseAndIncentivePaid(
                    factors, w.assetCash, asset.assetType);

                // Remove liquidity token balance
                asset.notional = asset.notional.subNoNeg(LT.unwrap(tokensToRemove));
                asset.storageState = AssetStorageState.Update;
                assetAmountRemaining = IA.wrap(0);
            }

            w.totalIncentivePaid = w.totalIncentivePaid.add(w.incentivePaid);
            w.totalCashClaim = w.totalCashClaim.add(w.assetCash);

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                factors.collateralCashGroup.currencyId,
                asset.maturity,
                Constants.FCASH_ASSET_TYPE,
                IU.unwrap(w.fCash)
            );

            if (assetAmountRemaining.isZero()) break;
        }

        return (w, assetAmountRemaining);
    }

    function _calculateNetCashIncreaseAndIncentivePaid(
        LiquidationFactors memory factors,
        IA assetCash,
        uint256 assetType
    ) private pure returns (IA netCashIncrease, IA incentivePaid) {
        // We can only recollateralize the local currency using the part of the liquidity token that
        // between the pre-haircut cash claim and the post-haircut cash claim. Part of the cash raised
        // is paid out as an incentive so that must be accounted for.
        // netCashIncrease = cashClaim * (1 - haircut)
        // netCashIncrease = netCashToAccount + incentivePaid
        // incentivePaid = netCashIncrease * incentivePercentage
        int256 haircut = int256(uint256(factors.collateralCashGroup.getLiquidityHaircut(assetType)));
        netCashIncrease = assetCash.scale(
            Constants.PERCENTAGE_DECIMALS.sub(haircut),
            Constants.PERCENTAGE_DECIMALS
        );
        incentivePaid = netCashIncrease.scale(
            Constants.TOKEN_REPO_INCENTIVE_PERCENT,
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
        IA collateralToWithdraw
    ) internal returns (IA) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        MarketParameters memory market;

        // Loop through the stored assets in reverse order. This ensures that we withdraw the longest dated
        // liquidity tokens first. Longer dated liquidity tokens will generally have larger haircuts and therefore
        // provide more benefit when withdrawn.
        for (uint256 i = portfolioState.storedAssets.length; (i--) > 0;) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (!_isValidWithdrawToken(asset, factors.collateralCashGroup.currencyId)) continue;

            (IA cashClaim, IU fCashClaim) = _loadMarketAndGetClaims(
                asset,
                factors.collateralCashGroup,
                market,
                blockTime
            );

            if (cashClaim.lte(collateralToWithdraw)) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                if (!factors.isCalculation) market.removeLiquidity(LT.wrap(asset.notional));

                collateralToWithdraw = collateralToWithdraw.sub(cashClaim);
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // NOTE: dust can accrue when withdrawing liquidity at this point
                LT tokensToRemove = LT.wrap(asset.notional).scale(
                    IA.unwrap(collateralToWithdraw), IA.unwrap(cashClaim)
                );

                if (!factors.isCalculation) {
                    (cashClaim, fCashClaim) = market.removeLiquidity(tokensToRemove);
                } else {
                    cashClaim = market.totalAssetCash.scale(LT.unwrap(tokensToRemove), LT.unwrap(market.totalLiquidity));
                    fCashClaim = market.totalfCash.scale(LT.unwrap(tokensToRemove), LT.unwrap(market.totalLiquidity));
                }

                // Remove liquidity token balance
                asset.notional = asset.notional.subNoNeg(LT.unwrap(tokensToRemove));
                asset.storageState = AssetStorageState.Update;
                collateralToWithdraw = IA.wrap(0);
            }

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                factors.collateralCashGroup.currencyId,
                asset.maturity,
                Constants.FCASH_ASSET_TYPE,
                IU.unwrap(fCashClaim)
            );

            if (collateralToWithdraw.isZero()) return IA.wrap(0);
        }

        return collateralToWithdraw;
    }

    function _isValidWithdrawToken(PortfolioAsset memory asset, uint256 currencyId) private pure returns (bool) {
        return (
            asset.currencyId == currencyId &&
            AssetHandler.isLiquidityToken(asset.assetType) &&
            // Defensive check to ensure that we only operate on unmodified assets
            asset.storageState == AssetStorageState.NoChange
        );
    }

    function _loadMarketAndGetClaims(
        PortfolioAsset memory asset,
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        uint256 blockTime
    ) private view returns (IA cashClaim, IU fCashClaim) {
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
        IA tmpAssetTransferAmount = collateralBalanceState.netAssetTransferInternalPrecision;
        collateralBalanceState.netAssetTransferInternalPrecision = IA.wrap(0);

        // Finalize liquidated account balance
        collateralBalanceState.finalize(liquidateAccount, accountContext, false);

        if (!accountContext.isBitmapEnabled()) {
            // Portfolio updates only happen if the account has liquidity tokens, which can only be the
            // case in a non-bitmapped portfolio.
            accountContext.storeAssetsAndUpdateContext(
                liquidateAccount,
                portfolio,
                true // is liquidation
            );
        }

        accountContext.setAccountContext(liquidateAccount);
        collateralBalanceState.netAssetTransferInternalPrecision = tmpAssetTransferAmount;
    }
}
