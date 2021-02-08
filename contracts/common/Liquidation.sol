// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;

import "./FreeCollateral.sol";
import "./ExchangeRate.sol";
import "./CashGroup.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

struct LiquidationFactors {
    int localAssetRequired;
    // These are denominated in AssetValue
    int localAvailable;
    int collateralAvailable;
    int collateralPerpetualTokenValue;
    int liquidationDiscount;
    ETHRate localETHRate;
    ETHRate collateralETHRate;
    CashGroupParameters localCashGroup;
    CashGroupParameters collateralCashGroup;
    MarketParameters[] localMarketStates;
    MarketParameters[] collateralMarketStates;
    bool hasCollateral;
}

library Liquidation {
    using SafeMath for uint;
    using SafeInt256 for int;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;
    using PortfolioHandler for PortfolioState;
    using CashGroup for CashGroupParameters;

    int internal constant LIQUIDATION_BUFFER = 1.01e18;
    int internal constant DUST = 1;

    /**
     * @notice Calculates liquidation factors, assumes portfolio has already been settled
     */
    function calculateLiquidationFactors(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime,
        uint localCurrencyId,
        uint collateralCurrencyId
    ) internal view returns (
        LiquidationFactors memory,
        PortfolioAsset[] memory
    ) {
        (
            // TODO: Get merged portfolio isnt necessary here since we know there is no trading...
            PortfolioAsset[] memory allActiveAssets,
            int[] memory netPortfolioValue
        ) = FreeCollateral.setupFreeCollateral(
            account,
            accountContext,
            portfolioState,
            balanceState,
            cashGroups,
            marketStates,
            blockTime
        );

        LiquidationFactors memory factors = getLiquidationFactors(
            localCurrencyId,
            collateralCurrencyId,
            balanceState,
            cashGroups,
            marketStates,
            netPortfolioValue
        );

        return (factors, allActiveAssets);
    }

    /**
     * @notice Calculates free collateral and liquidation factors required for the rest of the liquidation
     * procedure.
     */
    function getLiquidationFactors(
        uint localCurrencyId,
        uint collateralCurrencyId,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        int[] memory netPortfolioValue
    ) internal view returns (LiquidationFactors memory) {
        uint groupIndex;
        int netETHValue;
        LiquidationFactors memory factors;

        for (uint i; i < balanceState.length; i++) {
            int perpetualTokenValue;
            int netLocalAssetValue = balanceState[i].storedCashBalance;
            if (balanceState[i].storedPerpetualTokenBalance > 0) {
                // TODO: fill this out
                perpetualTokenValue = balanceState[i].getPerpetualTokenAssetValue();
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            // If this is true then there is some collateral value within the system. Set this
            // flag for the liquidate fcash function to check.
            if (netLocalAssetValue > 0) factors.hasCollateral = true;

            AssetRateParameters memory assetRate;
            if (cashGroups[groupIndex].currencyId == balanceState[i].currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                assetRate = cashGroups[groupIndex].assetRate;

                // Save cash groups and market states for checking liquidity token value and
                // fcash value
                if (balanceState[i].currencyId == localCurrencyId) {
                    factors.localCashGroup = cashGroups[groupIndex];
                    factors.localMarketStates = marketStates[groupIndex];
                } else if (balanceState[i].currencyId == collateralCurrencyId) {
                    factors.collateralCashGroup = cashGroups[groupIndex];
                    factors.collateralMarketStates = marketStates[groupIndex];
                }
                groupIndex += 1;
            } else {
                // TODO: there is a stateful and view version of this method
                assetRate = AssetRate.buildAssetRate(balanceState[i].currencyId);
            }

            // TODO: short circuit this if the currency is ETH
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(balanceState[i].currencyId);
            int ethValue = ethRate.convertToETH(
                assetRate.convertInternalToUnderlying(netLocalAssetValue)
            );
            netETHValue = netETHValue.add(ethValue);

            // Store relevant factors here, there are asset value denominated
            if (balanceState[i].currencyId == localCurrencyId) {
                factors.localAvailable = netLocalAssetValue;
                factors.localETHRate = ethRate;
            } else if (balanceState[i].currencyId == collateralCurrencyId) {
                factors.collateralAvailable = netLocalAssetValue;
                factors.collateralPerpetualTokenValue = perpetualTokenValue;
                factors.collateralETHRate = ethRate;
            }
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
    function withdrawLiquidityTokens(
        uint blockTime,
        int assetAmountRequired,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        PortfolioState memory portfolioState,
        int repoIncentive
    ) internal view returns (int, int) {
        require(portfolioState.newAssets.length == 0, "L: new assets exist");

        uint currencyId = cashGroup.currencyId;
        int incentivePaid;
        int assetAmountRemaining = assetAmountRequired;

        // NOTE: even if stored assets have been modified in memory as a result of the Asset.getRiskAdjustedPortfolioValue
        // method getting the haircut value will still work here because we do not reference the fCash value.
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (asset.assetType != Asset.LIQUIDITY_TOKEN_ASSET_TYPE
                && asset.currencyId != currencyId) continue;

            (uint marketIndex,  /* */) = cashGroup.getMarketIndex(asset.maturity, blockTime);
            MarketParameters memory market = cashGroup.getMarket(marketStates, marketIndex, blockTime, true);

            // NOTE: we do not give any credit to the haircut fCash in this procedure but it will end up adding
            // additional collateral value back into the account. It's probably too complex to deal with this so
            // we will just leave it as such.
            (int assetCash, int fCash) = Asset.getCashClaims(asset, market);

            // We can only recollateralize the local currency using the part of the liquidity token that
            // between the pre-haircut cash claim and the post-haircut cash claim. Part of the cash raised
            // is paid out as an incentive so that must be accounted for.
            // cashClaim - cashClaim * haircut = totalCashOut * (1 + incentive)
            // cashClaim * (1 - haircut) = totalCashOut * (1 + incentive)
            // totalCashOut = cashClaim * (1 - haircut) / (1 + incentive)
            // cashToAccount = totalCashOut * (1 - incentive)
            int totalCashOut = assetCash
                .mul(CashGroup.TOKEN_HAIRCUT_DECIMALS.sub(
                    int(cashGroup.getLiquidityHaircut(asset.maturity.sub(blockTime))))
                ).div(CashGroup.TOKEN_HAIRCUT_DECIMALS.add(repoIncentive));
            int cashToAccount = totalCashOut
                .mul(CashGroup.TOKEN_HAIRCUT_DECIMALS.sub(repoIncentive))
                .div(CashGroup.TOKEN_HAIRCUT_DECIMALS);

            if (cashToAccount < assetAmountRemaining) {
                // The additional cash is insufficient to cover asset amount required so we just remove
                // all of it.
                portfolioState.deleteAsset(i);
                market.totalLiquidity = market.totalLiquidity.sub(asset.notional);
                incentivePaid = incentivePaid.add(
                    totalCashOut.mul(repoIncentive).div(CashGroup.TOKEN_HAIRCUT_DECIMALS)
                );
                assetAmountRemaining = assetAmountRemaining - cashToAccount;
            } else {
                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                int tokensToRemove = asset.notional.mul(totalCashOut).div(assetAmountRemaining);
                fCash = tokensToRemove.mul(fCash).div(asset.notional);
                assetCash = tokensToRemove.mul(assetCash).div(asset.notional);

                // Remove liquidity token balance
                portfolioState.storedAssets[i].notional = asset.notional.sub(tokensToRemove);
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;
                market.totalLiquidity = market.totalLiquidity.sub(tokensToRemove);

                incentivePaid = incentivePaid.add(
                    assetAmountRemaining.mul(repoIncentive).div(CashGroup.TOKEN_HAIRCUT_DECIMALS)
                );
                assetAmountRemaining = 0;
            }

            portfolioState.addAsset(
                currencyId,
                asset.maturity,
                Asset.FCASH_ASSET_TYPE,
                fCash,
                false
            );
            market.totalfCash = market.totalfCash.sub(fCash);
            market.totalCurrentCash = market.totalCurrentCash.sub(assetCash);
            market.hasUpdated = true;

            if (assetAmountRemaining == 0) break;
        }

        return (incentivePaid, assetAmountRemaining);
    }

    /**
     * @notice Liquidates local liquidity tokens
     */
    function liquidateLocalLiquidityTokens(
        uint blockTime,
        BalanceState memory localBalanceContext,
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors
    ) internal view returns (int) {
        // TODO: should short circuit this if there are no liquidity tokens.

        (int incentivePaid, int assetAmountRemaining) = withdrawLiquidityTokens(
            blockTime,
            factors.localAssetRequired,
            factors.localCashGroup,
            factors.localMarketStates,
            portfolioState,
            CashGroup.TOKEN_REPO_INCENTIVE
        );

        localBalanceContext.netCashChange = localBalanceContext.netCashChange.add(
            // NOTE: incentive paid is already accounted for during the withdraw liquidity
            // token method so we don't need to subtract it again here
            factors.localAssetRequired.sub(assetAmountRemaining)
        );

        factors.localAssetRequired = assetAmountRemaining;
        return incentivePaid;
    }

    /**
     * @notice Calculates collateral liquidation, returns localToPurchase and perpetualTokensToTransfer
     */
    function liquidateCollateral(
        BalanceState memory localBalanceContext,
        BalanceState memory collateralBalanceContext,
        PortfolioState memory portfolioState,
        LiquidationFactors memory factors,
        int maxLiquidateAmount,
        uint blockTime
    ) internal view returns (int, int) {
        // First determine how much local currency is required for the liquidation.
        int localToTrade = calculateLocalToTrade(
            factors.localAssetRequired,
            factors.liquidationDiscount, // TODO: where to get this, maybe on ETH rate...
            factors.localETHRate.buffer,
            factors.localAvailable
        );

        if (maxLiquidateAmount > localToTrade) localToTrade = maxLiquidateAmount;

        int balanceAdjustment;
        int collateralCashClaim;
        int haircutCashClaim;
        if (factors.collateralCashGroup.currencyId != 0) {
            // Only do this if there is a cash group set for the collateral group, meaning
            // that they hold liquidity tokens or assets. It's possible that an account is holding
            // liquidity tokens denominated in collateral terms and we will have to withdraw those
            // tokens for the liquidation.
            (collateralCashClaim, haircutCashClaim) = calculateTokenCashClaims(
                portfolioState,
                factors.collateralCashGroup,
                factors.collateralMarketStates,
                blockTime
            );
        }

        // Since we are not liquidating fCash, we must adjust the collateral available figure to remove
        // fCash that does not net off negative balances.
        (factors.collateralAvailable, balanceAdjustment) = calculatePostfCashValue(
            factors.collateralAvailable,
            collateralBalanceContext,
            factors.collateralPerpetualTokenValue,
            collateralCashClaim
        );
        // If there is no collateral available after this then no liquidation is possible.
        require(factors.collateralAvailable > 0, "L: no collateral available");

        // Calculates the collateral to sell taking into account what's available in the cash claim
        (int collateralToSell, int localToPurchase) = calculateCollateralToSell(
            factors.liquidationDiscount,
            localToTrade,
            factors.collateralAvailable,
            factors.collateralETHRate,
            factors.localETHRate,
            haircutCashClaim
        );
        // It's possible that collateralToSell is zero even if localToTrade > 0, this can be caused
        // by very small amounts of localToTrade
        if (collateralToSell == 0) return (0, 0);

        // This figure represents how much cash value of collateral is available to transfer in the
        // account, not including cash claims in liquidity tokens. The balance adjustment from the
        // calculatePostfCashValue is used to ensure that negative fCash balances are net off properly
        // and we do not put the account further undercollateralized.
        int netAssetCash = collateralBalanceContext.storedCashBalance
            .add(collateralBalanceContext.netCashChange)
            .add(balanceAdjustment);

        if (netAssetCash > collateralToSell) {
            // Sufficient cash to cover collateral to sell
            collateralBalanceContext.netCashChange = collateralBalanceContext
                .netCashChange.sub(collateralToSell);

            return (localToPurchase, 0);
        } else if (netAssetCash > 0) {
            // Asset cash only partially covers collateral
            collateralBalanceContext.netCashChange = collateralBalanceContext
                .netCashChange.sub(netAssetCash);

            collateralToSell = collateralToSell.sub(netAssetCash);
        }

        // If asset cash is insufficient, perpetual liquidity tokens are next in the liquidation preference.
        // We calculate the proportional amount based on collateral to sell and return the amount to transfer.
        int perpetualTokensToTransfer;
        if (factors.collateralPerpetualTokenValue > collateralToSell) {
            perpetualTokensToTransfer = collateralBalanceContext.storedPerpetualTokenBalance
                .mul(collateralToSell)
                .div(factors.collateralPerpetualTokenValue);

            return (localToPurchase, perpetualTokensToTransfer);
        } else if (factors.collateralPerpetualTokenValue > 0) {
            // Transfer all the tokens in this case
            collateralToSell = collateralToSell.sub(factors.collateralPerpetualTokenValue);
            perpetualTokensToTransfer = collateralBalanceContext.storedPerpetualTokenBalance;
        }

        // Finally we withdraw liquidity tokens
        (/* int incentivePaid */, int amountRemaining) = withdrawLiquidityTokens(
            blockTime,
            collateralToSell,
            factors.collateralCashGroup,
            factors.collateralMarketStates,
            portfolioState,
            0 // We do not pay incentives here
        );

        // If we did not raise sufficient amount then something has gone wrong.
        require(amountRemaining > 0 && amountRemaining <= DUST, "L: liquidation failed");

        return (localToPurchase, perpetualTokensToTransfer);
    }

    function calculateTokenCashClaims(
        PortfolioState memory portfolioState,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        uint blockTime
    ) internal view returns (int, int) {
        int totalAssetCash;
        int totalHaircutAssetCash;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (asset.assetType != Asset.LIQUIDITY_TOKEN_ASSET_TYPE
                && asset.currencyId != cashGroup.currencyId) continue;

            (uint marketIndex,  /* */) = cashGroup.getMarketIndex(asset.maturity, blockTime);
            MarketParameters memory market = cashGroup.getMarket(marketStates, marketIndex, blockTime, true);

            (int assetCash, /* int fCash */) = Asset.getCashClaims(asset, market);
            totalAssetCash = totalAssetCash.add(assetCash);
            int haircut = int(cashGroup.getLiquidityHaircut(asset.maturity.sub(blockTime)));
            int haircutAssetCash = assetCash.mul(haircut).div(CashGroup.TOKEN_HAIRCUT_DECIMALS);
            totalHaircutAssetCash = totalHaircutAssetCash.add(haircutAssetCash);
        }

        return (totalAssetCash, totalHaircutAssetCash);
    }

    /**
     * @notice Adjusts collateral available and collateral balance post fCash value. We do not trade fCash in this
     * scenario so we want to only allow fCash to net out against negative collateral balance and no more.
     */
    function calculatePostfCashValue(
        int collateralAvailable,
        BalanceState memory collateralBalanceContext,
        int collateralPerpetualTokenValue,
        int collateralCashClaim
    ) internal pure returns (int, int) {
        int collateralBalance = collateralBalanceContext.storedCashBalance
            .add(collateralBalanceContext.netCashChange)
            .add(collateralPerpetualTokenValue);

        int fCashValue = collateralAvailable
            .sub(collateralBalance)
            .sub(collateralCashClaim);

        if (fCashValue <= 0) {
            // If we have negative fCashValue then no adjustments are required.
            return (collateralAvailable, 0);
        }

        if (collateralBalance >= 0) {
            // If payer has a positive collateral balance then we don't need to net off against it. We remove
            // the fCashValue from net available.
            return (collateralAvailable.sub(fCashValue), 0);
        }

        // In these scenarios the payer has a negative collateral balance and we need to partially offset the balance
        // so that the payer gets the benefit of their positive fCashValue.
        int netBalanceWithfCashValue = collateralBalance.add(fCashValue);
        if (netBalanceWithfCashValue > 0) {
            // We have more fCashValue than required to net out the balance. We remove the excess from collateralNetAvailable
            // and adjust the netPayerBalance to zero.
            return (collateralAvailable.sub(netBalanceWithfCashValue), collateralBalance.neg());
        } else {
            // We don't have enough fCashValue to net out the balance. collateralNetAvailable is unchanged because it already takes
            // into account this netting. We adjust the balance to account for fCash only
            return (collateralAvailable, fCashValue);
        }
    }

    function calculateCollateralToSell(
        int liquidationDiscount,
        int localToTrade,
        int collateralAvailable,
        ETHRate memory localETHRate,
        ETHRate memory collateralETHRate,
        int haircutCashClaim
    ) internal pure returns (int, int) {
        int rate = ExchangeRate.exchangeRate(localETHRate, collateralETHRate);
        int collateralToSell = rate
            .mul(localToTrade)
            .mul(liquidationDiscount)
            // TODO: collapse these decimals into one multiply or divide
            .mul(collateralETHRate.baseDecimals)
            .div(localETHRate.rateDecimals)
            .div(localETHRate.baseDecimals)
            .div(CashGroup.TOKEN_HAIRCUT_DECIMALS);

        if (collateralAvailable.add(haircutCashClaim) >= collateralToSell) {
            // Sufficient collateral available to cover all of local to trade
            return (collateralToSell, localToTrade);
        } else {
            // In sufficient collateral so we calculate the amount required here
            collateralToSell = collateralAvailable.add(haircutCashClaim);
            // This is the inverse of the calculation above
            int localToPurchase = collateralToSell
                .mul(localETHRate.rateDecimals)
                .mul(localETHRate.baseDecimals)
                .mul(CashGroup.TOKEN_HAIRCUT_DECIMALS)
                .div(rate)
                .div(liquidationDiscount)
                .div(collateralETHRate.baseDecimals);

            return (collateralToSell, localToPurchase);
        }
    }

    function calculateLocalToTrade(
        int localAssetRequired,
        int liquidationDiscount,
        int localCurrencyBuffer,
        int localAvailable
    ) internal pure returns (int) {
        // We calculate the max amount of local currency that the liquidator can trade for here. We set it to the min of the
        // localAvailable and the localCurrencyToTrade figure calculated below. The math for this figure is as follows:

        // The benefit given to free collateral in local currency terms:
        //   localCurrencyBenefit = localCurrencyToTrade * localCurrencyBuffer
        // NOTE: this only holds true while maxLocalCurrencyDebt <= 0

        // The penalty for trading collateral currency in local currency terms:
        //   localCurrencyPenalty = collateralCurrencyPurchased * exchangeRate[collateralCurrency][localCurrency]
        //
        //  netLocalCurrencyBenefit = localCurrencyBenefit - localCurrencyPenalty
        //
        // collateralCurrencyPurchased = localCurrencyToTrade * exchangeRate[localCurrency][collateralCurrency] * liquidationDiscount
        // localCurrencyPenalty = localCurrencyToTrade * exchangeRate[localCurrency][collateralCurrency] * exchangeRate[collateralCurrency][localCurrency] * liquidationDiscount
        // localCurrencyPenalty = localCurrencyToTrade * liquidationDiscount
        // netLocalCurrencyBenefit =  localCurrencyToTrade * localCurrencyBuffer - localCurrencyToTrade * liquidationDiscount
        // netLocalCurrencyBenefit =  localCurrencyToTrade * (localCurrencyBuffer - liquidationDiscount)
        // localCurrencyToTrade =  netLocalCurrencyBenefit / (buffer - discount)
        //
        // localCurrencyRequired is netLocalCurrencyBenefit after removing liquidity tokens
        // localCurrencyToTrade =  localCurrencyRequired / (buffer - discount)
        require(localAssetRequired > 0, "L: local required negative");
        require(localAvailable < 0, "L: no local debt");

        int localCurrencyToTrade = localAssetRequired
            .mul(ExchangeRate.MULTIPLIER_DECIMALS)
            .div(localCurrencyBuffer.sub(liquidationDiscount));

        // We do not trade past the amount of local currency debt the account has or this benefit will not longer be effective.
        localCurrencyToTrade = localAvailable.neg() < localCurrencyToTrade ? localAvailable.neg() : localCurrencyToTrade;

        return localCurrencyToTrade;
    }

    function calculatefCash(
        uint[] memory fCashAssetMaturities,
        int maxLiquidateAmount,
        LiquidationFactors memory factors,
        PortfolioState memory portfolioState
    ) internal pure returns (int) {
        // TODO: must check that has collateral is false but check collateral currency again in case the
        // liquidation is falling through from liquidating collateral to liquidating fcash
        require(!factors.hasCollateral, "L: has collateral");
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            if (portfolioState.storedAssets[i].storageState == AssetStorageState.Delete) continue;
            if (portfolioState.storedAssets[i].assetType == Asset.LIQUIDITY_TOKEN_ASSET_TYPE) {
                revert("L: has liquidity tokens");
            }
        }

        int localToTrade = calculateLocalToTrade(
            factors.localAssetRequired,
            factors.liquidationDiscount, // TODO: where to get this, maybe on ETH rate...
            factors.localETHRate.buffer,
            factors.localAvailable
        );
        if (maxLiquidateAmount > localToTrade) localToTrade = maxLiquidateAmount;

        // Calculates the collateral to sell taking into account what's available in the cash claim
        (int collateralToSell, int localToPurchase) = calculateCollateralToSell(
            factors.liquidationDiscount,
            localToTrade,
            factors.collateralAvailable,
            factors.collateralETHRate,
            factors.localETHRate,
            0 // No haircut cash claim
        );

        // It may be possible that the fCash asset is in "newAssets" 
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            // TODO: transfer fCash to liquidator in exchange for payment

        }
    }

}