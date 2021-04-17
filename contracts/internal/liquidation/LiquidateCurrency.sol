// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./LiquidationHelpers.sol";
import "../valuation/ExchangeRate.sol";
import "../markets/CashGroup.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library LiquidateCurrency {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;

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

            nTokensToLiquidate = LiquidationHelpers.calculateMaxLiquidationAmount(
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
            // We don't change netCashBalance here because all the collateral withdrawn is going
            // to go to the liquidator
            collateralRemaining = _withdrawCollateralLiquidityTokens(
                portfolio,
                factors,
                blockTime,
                collateralRemaining
            );
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
            ) = LiquidationHelpers.calculateLocalToPurchase(
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
            LiquidationHelpers.calculateCrossCurrencyBenefitAndDiscount(factors);
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

        collateralToRaise = LiquidationHelpers.calculateMaxLiquidationAmount(
            collateralToRaise,
            factors.collateralAvailable,
            0 // will check userSpecifiedAmount below
        );

        int256 localToPurchase;
        (collateralToRaise, localToPurchase) = LiquidationHelpers.calculateLocalToPurchase(
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
            ) = LiquidationHelpers.calculateLocalToPurchase(
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
