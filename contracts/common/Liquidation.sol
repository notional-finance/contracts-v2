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
    ) private returns (AccountStorage memory, LiquidationFactors memory, PortfolioAsset[] memory) {
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

        return (accountContext, factors, portfolio);
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
        // exchangeRate = localRate / collateralRate
        // discountedExchangeRate = exchangeRate / liquidationDiscount
        //                        = localRate * liquidationDiscount / collateralRate
        // localToPurchase = collateralPV * discountedExchangeRate
        // localToPurchase = collateralPV * liquidationDiscount * localRate / collateralRate
        int localToPurchase = collateralPresentValue
            .mul(liquidationDiscount)
            .mul(factors.localETHRate.rateDecimals)
            // TODO: should this be multiply instead?
            .div(ExchangeRate.exchangeRate(factors.localETHRate, factors.collateralETHRate))
            .div(ExchangeRate.MULTIPLIER_DECIMALS);

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
        AccountStorage memory accountContext,
        PortfolioAsset[] memory portfolio,
        uint currencyId,
        uint maturity
    ) private view returns (int) {
        if (accountContext.bitmapCurrencyId == currencyId) {
            int notional = BitmapAssetsHandler.getifCashNotional(liquidateAccount, currencyId, maturity);
            require(notional > 0, "Invalid fCash asset");
        }

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
        address liquidateAccount,
        uint localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime
    ) internal returns (BalanceState memory, int) {
        (
            AccountStorage memory accountContext,
            LiquidationFactors memory factors,
            PortfolioAsset[] memory portfolio
        ) = preLiquidationActions(liquidateAccount, localCurrency, 0, blockTime);

        int benefitRequired = factors.localETHRate.convertETHTo(factors.netETHValue.neg())
            .mul(ExchangeRate.MULTIPLIER_DECIMALS)
            .div(factors.localETHRate.buffer);

        BalanceState memory liquidatedBalanceState = BalanceHandler.buildBalanceState(liquidateAccount, localCurrency, accountContext);

        int repoIncentivePaid;
        if (hasLiquidityTokens(portfolio, localCurrency)) {
            PortfolioState memory portfolioState = PortfolioState({
                storedAssets: portfolio,
                newAssets: new PortfolioAsset[](0),
                lastNewAssetIndex: 0,
                storedAssetLength: portfolio.length
            });

            (
                repoIncentivePaid,
                liquidatedBalanceState.netCashChange,
                benefitRequired
            ) = withdrawLocalLiquidityTokens(portfolioState, factors, blockTime, benefitRequired);
        }

        // This will not underflow, checked when saving parameters
        int haircutDiff = int(uint8(factors.perpetualTokenParameters[PerpetualToken.LIQUIDATION_HAIRCUT_PERCENTAGE])) -
                int(uint8(factors.perpetualTokenParameters[PerpetualToken.PV_HAIRCUT_PERCENTAGE])) * CashGroup.PERCENTAGE_DECIMALS;

        // benefitGained = perpTokensToLiquidate * (liquidatedPV - freeCollateralPV)
        // benefitGained = perpTokensToLiquidate * perpTokenPV * (liquidationHaircut - pvHaircut)
        // perpTokensToLiquidate = benefitGained / (perpTokenPV * (liquidationHaircut - pvHaircut))
        int perpetualTokensToLiquidate = benefitRequired
            .mul(TokenHandler.INTERNAL_TOKEN_PRECISION)
            .div(factors.perpetualTokenValue.mul(haircutDiff).div(CashGroup.PERCENTAGE_DECIMALS));
        
        perpetualTokensToLiquidate = calculateMaxLiquidationAmount(
            perpetualTokensToLiquidate,
            liquidatedBalanceState.storedPerpetualTokenBalance,
            int(maxPerpetualTokenLiquidation)
        );
        liquidatedBalanceState.netPerpetualTokenTransfer = perpetualTokensToLiquidate.neg();

        return (liquidatedBalanceState, repoIncentivePaid);
    }

    /**
     * @notice Calculates free collateral and liquidation factors required for the rest of the liquidation
     * procedure.
     */
    function getLiquidationFactorsStateful(
        address account,
        uint localCurrencyId,
        uint collateralCurrencyId,
        bytes20 currencies,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue,
        uint blockTime
    ) internal returns (LiquidationFactors memory) {
        require(cashGroups.length == netPortfolioValue.length); // dev: missing cash groups

        uint groupIndex;
        int netETHValue;
        LiquidationFactors memory factors;

        while (currencies != 0) {
            uint currencyId = uint(uint16(bytes2(currencies)));
            int netLocalAssetValue = _getBalances(account, currencyId, collateralCurrencyId, factors);

            AssetRateParameters memory assetRate;
            if (cashGroups.length > groupIndex && cashGroups[groupIndex].currencyId == currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                assetRate = cashGroups[groupIndex].assetRate;

                // Save cash groups and market states for checking liquidity token value and
                // fcash value
                if (currencyId == localCurrencyId) {
                    factors.localCashGroup = cashGroups[groupIndex];
                } else if (currencyId == collateralCurrencyId) {
                    factors.collateralCashGroup = cashGroups[groupIndex];
                }
                groupIndex += 1;
            } else {
                assetRate = AssetRate.buildAssetRateStateful(currencyId);
            }

            // If this is true then there is some collateral value within the system. Set this
            // flag for the liquidate fcash function to check.
            if (netLocalAssetValue > 0) factors.hasCollateral = true;

            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
            int ethValue = ethRate.convertToETH(
                assetRate.convertInternalToUnderlying(netLocalAssetValue)
            );
            netETHValue = netETHValue.add(ethValue);

            // Store relevant factors here
            if (currencyId == localCurrencyId) {
                factors.localAvailable = netLocalAssetValue;
                factors.localETHRate = ethRate;
                // Assign this here in case localCashGroup is not assigned above
                factors.localCashGroup.assetRate = assetRate;
            } else if (currencyId == collateralCurrencyId) {
                factors.collateralAvailable = netLocalAssetValue;
                factors.collateralETHRate = ethRate;
            }

            currencies = currencies << 16;
        }

        require(netETHValue < 0, "L: sufficient free collateral");
        int localUnderlyingRequired = factors.localETHRate.convertETHTo(
            // Bump the eth value by a small amount to account for dust and loss of precision during
            // exchange rate conversion
            netETHValue.mul(LIQUIDATION_BUFFER).div(ExchangeRate.ETH_DECIMALS).neg()
        );

        // Convert back to asset values because liquidation will occur using cash balances that are
        // denominated in asset values
        factors.localAssetRequired = factors.localCashGroup.assetRate.convertInternalFromUnderlying(
            localUnderlyingRequired
        );

        return factors;
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
    ) internal view returns (int, int, int) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        int totalIncentivePaid;
        int totalCashClaim;

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
            (int assetCash, int fCash) = asset.getCashClaims(market);

            int netCashIncrease;
            {
                // We can only recollateralize the local currency using the part of the liquidity token that
                // between the pre-haircut cash claim and the post-haircut cash claim. Part of the cash raised
                // is paid out as an incentive so that must be accounted for.
                // netCashIncrease = cashClaim * (1 - haircut)
                // netCashIncrease = netCashToAccount + incentivePaid
                // incentivePaid = netCashIncrease * incentive
                int haircut = int(factors.cashGroup.getLiquidityHaircut(asset.assetType));
                netCashIncrease = assetCash
                    .mul(CashGroup.PERCENTAGE_DECIMALS.sub(haircut))
                    .div(CashGroup.PERCENTAGE_DECIMALS);
            }
            int incentivePaid = netCashIncrease.mul(TOKEN_REPO_INCENTIVE_PERCENT).div(CashGroup.PERCENTAGE_DECIMALS);

            // (netCashToAccount <= assetAmountRemaining)
            if (netCashIncrease.subNoNeg(incentivePaid) <= assetAmountRemaining) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // assetAmountRemaining = assetAmountRemaining - netCashToAccount
                // netCashToAccount = netCashIncrease - incentivePaid
                // overflow checked above
                assetAmountRemaining = assetAmountRemaining - netCashIncrease.sub(incentivePaid);
            } else {
                // incentivePaid
                incentivePaid = assetAmountRemaining.mul(TOKEN_REPO_INCENTIVE_PERCENT).div(CashGroup.PERCENTAGE_DECIMALS);

                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                int tokensToRemove = asset.notional.mul(assetAmountRemaining).div(netCashIncrease);

                (assetCash, fCash) = market.removeLiquidity(tokensToRemove);

                // Remove liquidity token balance
                portfolioState.storedAssets[i].notional = asset.notional.subNoNeg(tokensToRemove);
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;
                assetAmountRemaining = 0;
            }

            totalIncentivePaid = totalIncentivePaid.add(incentivePaid);
            totalCashClaim = totalCashClaim.add(assetCash);

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                factors.cashGroup.currencyId,
                asset.maturity,
                AssetHandler.FCASH_ASSET_TYPE,
                fCash,
                false
            );

            if (assetAmountRemaining == 0) break;
        }

        return (
            totalIncentivePaid,
            // Net cash change for liquidated account
            totalCashClaim.sub(totalIncentivePaid),
            // Remaining amount to raise (if any)
            assetAmountRemaining
        );
    }

    /**
     * @dev Similar to withdraw liquidity tokens, except there is no incentive paid and we do not worry about
     * haircut amounts, we simply withdraw as much collateral as needed.
     */
    function withdrawCollateralLiquidityTokens(
        uint blockTime,
        int collateralToWithdraw,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        PortfolioState memory portfolioState
    ) internal view {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        int collateralRemaining = collateralToWithdraw;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (!AssetHandler.isLiquidityToken(asset.assetType) || asset.currencyId != cashGroup.currencyId) continue;
            
            MarketParameters memory market = cashGroup.getMarket(marketStates, asset.assetType - 1, blockTime, true);
            (int cashClaim, int fCashClaim) = asset.getCashClaims(market);

            if (cashClaim <= collateralRemaining) {
                // The additional cash is insufficient to cover asset amount required so we just remove all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // overflow checked above
                collateralRemaining = collateralRemaining - cashClaim;
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // notional * collateralRemaining / cashClaim
                int tokensToRemove = asset.notional.mul(collateralRemaining).div(cashClaim);
                (cashClaim, fCashClaim) = market.removeLiquidity(tokensToRemove);

                // Remove liquidity token balance
                portfolioState.storedAssets[i].notional = asset.notional.subNoNeg(tokensToRemove);
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;
                collateralRemaining = 0;
            }

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                cashGroup.currencyId,
                asset.maturity,
                AssetHandler.FCASH_ASSET_TYPE,
                fCashClaim,
                false
            );

            if (collateralRemaining == 0) return;
        }

        require(collateralRemaining == 0, "L: liquidation failed");
    }

}
