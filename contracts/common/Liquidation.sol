// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetHandler.sol";
import "./FreeCollateral.sol";
import "./ExchangeRate.sol";
import "./CashGroup.sol";
import "../storage/AccountContextHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

struct LiquidationFactors {
    int localAssetRequired;
    // These are denominated in AssetValue
    int localAvailable;
    int collateralAvailable;
    int collateralPerpetualTokenValue;
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
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using AccountContextHandler for AccountStorage;
    using Market for MarketParameters;

    int internal constant LIQUIDATION_BUFFER = 1.01e18;
    int internal constant DUST = 1;

    /**
     * @notice Calculates liquidation factors, assumes portfolio has already been settled
     */
    function calculateLiquidationFactors(
        address account,
        AccountStorage memory accountContext,
        PortfolioAsset[] memory portfolio,
        uint blockTime,
        uint localCurrencyId,
        uint collateralCurrencyId
    ) internal returns (LiquidationFactors memory) {
        int[] memory netPortfolioValue;
        CashGroupParameters[] memory cashGroups;
        MarketParameters[][] memory marketStates;

        if (portfolio.length > 0){
            (cashGroups, marketStates) = FreeCollateral.getAllCashGroupsStateful(portfolio);

            netPortfolioValue = AssetHandler.getPortfolioValue(
                portfolio,
                cashGroups,
                marketStates,
                blockTime,
                true // Must be risk adjusted
            );
        }

        return getLiquidationFactorsStateful(
            account,
            localCurrencyId,
            collateralCurrencyId,
            accountContext.getActiveCurrencyBytes(),
            cashGroups,
            netPortfolioValue,
            blockTime
        );
    }

    function _getBalances(
        address account,
        uint currencyId,
        uint collateralCurrencyId,
        LiquidationFactors memory factors
    ) private view returns (int) {
        (
            int netLocalAssetValue,
            int perpTokenBalance,
            /* */
        ) = BalanceHandler.getBalanceStorage(account, currencyId);

        if (perpTokenBalance > 0) {
            // PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(
            //     currencyId
            // );
            // // TODO: this will return an asset rate as well, so we can use it here
            // int perpetualTokenValue = FreeCollateral.getPerpetualTokenAssetValue(
            //     perpToken,
            //     perpTokenBalance,
            //     blockTime
            // );
            // netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);

            // if (currencyId == collateralCurrencyId) {
            //     factors.collateralPerpetualTokenValue = perpetualTokenValue;
            // }
        }

        return (netLocalAssetValue);
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
    function withdrawLiquidityTokens(
        uint blockTime,
        int assetAmountRemaining,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        PortfolioState memory portfolioState,
        int repoIncentive
    ) internal view returns (int[] memory, int) {
        require(portfolioState.newAssets.length == 0); // dev: new assets in portfolio
        int[] memory withdrawFactors = new int[](5);
        // withdrawFactors[0] = assetCash
        // withdrawFactors[1] = fCash
        // withdrawFactors[2] = netCashIncrease
        // withdrawFactors[3] = incentivePaid
        // withdrawFactors[4] = totalCashClaim

        // NOTE: even if stored assets have been modified in memory as a result of the Asset.getRiskAdjustedPortfolioValue
        // method getting the haircut value will still work here because we do not reference the fCash value.
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (!AssetHandler.isLiquidityToken(asset.assetType) || asset.currencyId != cashGroup.currencyId) continue;
            
            MarketParameters memory market = cashGroup.getMarket(marketStates, asset.assetType - 1, blockTime, true);

            // NOTE: we do not give any credit to the haircut fCash in this procedure but it will end up adding
            // additional collateral value back into the account. It's probably too complex to deal with this so
            // we will just leave it as such.
            // (assetCash, fCash)
            (withdrawFactors[0], withdrawFactors[1]) = asset.getCashClaims(market);

            {
                // We can only recollateralize the local currency using the part of the liquidity token that
                // between the pre-haircut cash claim and the post-haircut cash claim. Part of the cash raised
                // is paid out as an incentive so that must be accounted for.
                // netCashIncrease = cashClaim * (1 - haircut)
                // netCashIncrease = netCashToAccount + incentivePaid
                // incentivePaid = netCashIncrease * incentive
                int haircut = int(cashGroup.getLiquidityHaircut(asset.assetType));
                // netCashIncrease
                withdrawFactors[2] = withdrawFactors[0]
                    .mul(CashGroup.PERCENTAGE_DECIMALS.sub(haircut))
                    .div(CashGroup.PERCENTAGE_DECIMALS);
            }
            int incentivePaid = withdrawFactors[2].mul(repoIncentive).div(Market.RATE_PRECISION);

            // ((netCashIncrease - incentivePaid) < assetAmountRemaining))
            // (netCashToAccount <= assetAmountRemaining)
            if (withdrawFactors[2].subNoNeg(incentivePaid) <= assetAmountRemaining) {
                // The additional cash is insufficient to cover asset amount required so we just remove
                // all of it.
                portfolioState.deleteAsset(i);
                market.removeLiquidity(asset.notional);

                // assetAmountRemaining = assetAmountRemaining - netCashToAccount
                // netCashToAccount = netCashIncrease - incentivePaid
                // overflow checked above
                assetAmountRemaining = assetAmountRemaining - withdrawFactors[2].sub(incentivePaid);
            } else {
                // incentivePaid
                incentivePaid = assetAmountRemaining.mul(repoIncentive).div(Market.RATE_PRECISION);

                // Otherwise remove a proportional amount of liquidity tokens to cover the amount remaining.
                // notional * assetAmountRemaining / totalCashIncrease
                int tokensToRemove = asset.notional
                    .mul(assetAmountRemaining)
                    .div(withdrawFactors[2]);

                // assetCash, fCash
                (withdrawFactors[0], withdrawFactors[1]) = market.removeLiquidity(tokensToRemove);

                // Remove liquidity token balance
                portfolioState.storedAssets[i].notional = asset.notional.subNoNeg(tokensToRemove);
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;
                assetAmountRemaining = 0;
            }

            // incentivePaid
            withdrawFactors[3] = withdrawFactors[3].add(incentivePaid);
            // totalCashToAccount
            withdrawFactors[4] = withdrawFactors[4].add(withdrawFactors[0]);

            // Add the netfCash asset to the portfolio since we've withdrawn the liquidity tokens
            portfolioState.addAsset(
                cashGroup.currencyId,
                asset.maturity,
                AssetHandler.FCASH_ASSET_TYPE,
                withdrawFactors[1],
                false
            );

            if (assetAmountRemaining == 0) break;
        }

        // This is pretty ugly but we have to deal with stack issues
        return (withdrawFactors, assetAmountRemaining);
    }

    /**
     * @notice Liquidates local liquidity tokens
     */
    function liquidateLocalLiquidityTokens(
        LiquidationFactors memory factors,
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal view returns (int, int) {
        // TODO: should short circuit this if there are no liquidity tokens.

        (int[] memory withdrawFactors, int assetAmountRemaining) = withdrawLiquidityTokens(
            blockTime,
            factors.localAssetRequired,
            factors.localCashGroup,
            factors.localMarketStates,
            portfolioState,
            factors.localCashGroup.getLiquidityTokenRepoDiscount()
        );

        factors.localAssetRequired = assetAmountRemaining;
        // (incentivePaid, netCashChange = (totalCashToAccount - incentivePaid))
        return (withdrawFactors[3], withdrawFactors[4].subNoNeg(withdrawFactors[3]));
    }

    /**
     * @notice Calculates collateral liquidation, returns localToPurchase and perpetualTokensToTransfer
     */
    function liquidateCollateral(
        LiquidationFactors memory factors,
        BalanceState memory collateralBalanceContext,
        PortfolioState memory portfolioState,
        int maxLiquidateAmount,
        uint blockTime
    ) internal view returns (int) {
        require(maxLiquidateAmount >= 0); // dev: invalid max liquidate

        // First determine how much local currency is required for the liquidation.
        int localToTrade = calculateLocalToTrade(factors);

        if (maxLiquidateAmount != 0 && maxLiquidateAmount < localToTrade) {
            localToTrade = maxLiquidateAmount;
        }

        int balanceAdjustment;
        int collateralCashClaim;
        if (factors.collateralCashGroup.currencyId != 0) {
            // Only do this if there is a cash group set for the collateral group, meaning
            // that they hold liquidity tokens or assets. It's possible that an account is holding
            // liquidity tokens denominated in collateral terms and we will have to withdraw those
            // tokens for the liquidation.
            collateralCashClaim = calculateTokenCashClaims(
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
        require(factors.collateralAvailable > 0); // dev: no collateral available post fcash

        // Calculates the collateral to sell taking into account what's available in the cash claim
        (int collateralToSell, int localToPurchase) = calculateCollateralToSell(factors, localToTrade);

        // It's possible that collateralToSell is zero even if localToTrade > 0, this can be caused
        // by very small amounts of localToTrade
        if (collateralToSell == 0) return 0;

        return calculateCollateralTransfers(
            factors,
            collateralBalanceContext,
            portfolioState,
            balanceAdjustment,
            localToPurchase,
            collateralToSell,
            blockTime
        );
    }

    function calculateCollateralTransfers(
        LiquidationFactors memory factors,
        BalanceState memory collateralBalanceContext,
        PortfolioState memory portfolioState,
        int balanceAdjustment,
        int localToPurchase,
        int collateralToSell,
        uint blockTime
    ) internal view returns (int) {
        // This figure represents how much cash value of collateral is available to transfer in the
        // account, not including cash claims in liquidity tokens. The balance adjustment from the
        // calculatePostfCashValue is used to ensure that negative fCash balances are net off properly
        // and we do not put the account further undercollateralized.
        int netAssetCash = collateralBalanceContext.storedCashBalance
            .add(collateralBalanceContext.netCashChange)
            .add(balanceAdjustment);

        if (netAssetCash >= collateralToSell) {
            // Sufficient cash to cover collateral to sell
            collateralBalanceContext.netAssetTransferInternalPrecision = collateralToSell.neg();
            return localToPurchase;
        } else if (netAssetCash > 0) {
            // Asset cash only partially covers collateral
            collateralBalanceContext.netAssetTransferInternalPrecision = netAssetCash.neg();
            collateralToSell = collateralToSell.sub(netAssetCash);
        }

        // If asset cash is insufficient, perpetual liquidity tokens are next in the liquidation preference.
        // We calculate the proportional amount based on collateral to sell and return the amount to transfer.
        if (factors.collateralPerpetualTokenValue >= collateralToSell) {
            collateralBalanceContext.netPerpetualTokenTransfer = (
                collateralBalanceContext.storedPerpetualTokenBalance
                    .mul(collateralToSell)
                    .div(factors.collateralPerpetualTokenValue).neg()
            );

            return localToPurchase;
        } else if (factors.collateralPerpetualTokenValue > 0) {
            // Transfer all the tokens in this case
            collateralToSell = collateralToSell.sub(factors.collateralPerpetualTokenValue);
            collateralBalanceContext.netPerpetualTokenTransfer = collateralBalanceContext.storedPerpetualTokenBalance.neg();
        }

        // Finally we withdraw liquidity tokens
        withdrawCollateralLiquidityTokens(
            blockTime,
            collateralToSell,
            factors.collateralCashGroup,
            factors.collateralMarketStates,
            portfolioState
        );

        return localToPurchase;
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

    function calculateTokenCashClaims(
        PortfolioState memory portfolioState,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory marketStates,
        uint blockTime
    ) internal view returns (int) {
        int totalAssetCash;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) continue;
            if (!AssetHandler.isLiquidityToken(asset.assetType) || asset.currencyId != cashGroup.currencyId) continue;

            MarketParameters memory market = cashGroup.getMarket(marketStates, asset.assetType - 1, blockTime, true);

            (int assetCash, /* int fCash */) = asset.getCashClaims(market);
            totalAssetCash = totalAssetCash.add(assetCash);
        }

        return totalAssetCash;
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
            // Collateral cash claim is not included in the above because we have to calculate how
            // much cash claim to remove in calculateCollateralToSell
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

    /**
     * @notice Calculates the collateral amount to sell in exchange for local currency, accounting for
     * the liquidation discount and potential liquidity token claims.
     */
    function calculateCollateralToSell(
        LiquidationFactors memory factors,
        int localToTrade
    ) internal pure returns (int, int) {
        int liquidationDiscount = factors.localETHRate.liquidationDiscount > factors.collateralETHRate.liquidationDiscount ?
            factors.localETHRate.liquidationDiscount : factors.collateralETHRate.liquidationDiscount;

        int rate = ExchangeRate.exchangeRate(factors.localETHRate, factors.collateralETHRate);
        int collateralToSell = rate
            .mul(localToTrade)
            .mul(liquidationDiscount);

        // TODO: collapse these decimals into one multiply or divide
        collateralToSell = collateralToSell
            .div(factors.localETHRate.rateDecimals)
            .div(ExchangeRate.MULTIPLIER_DECIMALS);

        if (factors.collateralAvailable >= collateralToSell) {
            // Sufficient collateral available to cover all of local to trade
            return (collateralToSell, localToTrade);
        } else {
            // Insufficient collateral so we calculate the amount required here
            collateralToSell = factors.collateralAvailable;
            // This is the inverse of the calculation above
            int localToPurchase = collateralToSell
                .mul(factors.localETHRate.rateDecimals);
            
            localToPurchase = localToPurchase
                .mul(ExchangeRate.MULTIPLIER_DECIMALS)
                .div(rate)
                .div(liquidationDiscount);

            return (collateralToSell, localToPurchase);
        }
    }

    function calculateLocalToTrade(LiquidationFactors memory factors) internal pure returns (int) {
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
        require(factors.localAssetRequired > 0); // dev: no local asset required
        require(factors.localAvailable < 0); // dev: no local debt

        int liquidationDiscount = factors.localETHRate.liquidationDiscount > factors.collateralETHRate.liquidationDiscount ?
            factors.localETHRate.liquidationDiscount : factors.collateralETHRate.liquidationDiscount;

        int localCurrencyToTrade = factors.localAssetRequired
            .mul(ExchangeRate.MULTIPLIER_DECIMALS)
            .div(factors.localETHRate.buffer.sub(liquidationDiscount));

        // We do not trade past the amount of local currency debt the account has or this benefit will not longer be effective.
        localCurrencyToTrade = factors.localAvailable.neg() < localCurrencyToTrade ? factors.localAvailable.neg() : localCurrencyToTrade;

        return localCurrencyToTrade;
    }

    function liquidatefCash(
        LiquidationFactors memory factors,
        uint[] memory fCashAssetMaturities,
        int maxLiquidateAmount,
        PortfolioState memory portfolioState
    ) internal pure returns (int) {
        // TODO: must check that has collateral is false but check collateral currency again in case the
        // liquidation is falling through from liquidating collateral to liquidating fcash
        require(!factors.hasCollateral, "L: has collateral");
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            if (portfolioState.storedAssets[i].storageState == AssetStorageState.Delete) continue;
            require(
                !AssetHandler.isLiquidityToken(portfolioState.storedAssets[i].assetType),
                "L: has liquidity tokens"
            );
        }

        int localToTrade = calculateLocalToTrade(factors);
        if (maxLiquidateAmount > localToTrade) localToTrade = maxLiquidateAmount;

        // Calculates the collateral to sell taking into account what's available in the cash claim
        (int collateralToSell, int localToPurchase) = calculateCollateralToSell(factors, localToTrade);

        // It may be possible that the fCash asset is in "newAssets" due to liquidity token
        // settlement or withdraw
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            // TODO: transfer fCash to liquidator in exchange for payment
            // get asset present value at discounted rate, calculate share to transfer
        }
    }

}
