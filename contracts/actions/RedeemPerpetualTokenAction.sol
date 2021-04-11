// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Market.sol";
import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "./FreeCollateralExternal.sol";
import "./SettleAssetsExternal.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract RedeemPerpetualTokenAction {
    using SafeInt256 for int;
    using SafeMath for uint;
    using BalanceHandler for BalanceState;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using PerpetualToken for PerpetualTokenPortfolio;

    event RedeemPerpetualToken(address indexed redeemer, uint16 currencyId, uint88 tokensRedeemed);

    /**
     * @notice When redeeming perpetual tokens via the batch they must all be sold to cash and this
     * method will return the amount of asset cash sold.
     */
    function perpetualTokenRedeemViaBatch(
        uint currencyId,
        int tokensToRedeem
    ) external returns (int) {
        require(msg.sender == address(this), "Unauthorized caller");
        uint blockTime = block.timestamp;
        (
            int totalAssetCash,
            bool hasResidual,
            /* PortfolioAssets[] memory newfCashAssets */
        ) =  redeemPerpetualToken(currencyId, tokensToRedeem, true, blockTime);

        require(!hasResidual, "Cannot redeem via batch, residual");
        return totalAssetCash;
    }

    /**
     * @notice Allows accounts to redeem perpetual tokens into constituent assets and then absorb the assets
     * into their portfolio. Due to the complexity here, it is not allowed to be called during a batch trading
     * operation and must be done separately.
     */
    function perpetualTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem_,
        bool sellTokenAssets
    ) external {
        uint blockTime = block.timestamp;
        address redeemer = msg.sender;
        int tokensToRedeem = int(tokensToRedeem_);

        AccountStorage memory redeemerContext = AccountContextHandler.getAccountContext(redeemer);
        BalanceState memory redeemerBalance = BalanceHandler.buildBalanceState(
            redeemer, 
            currencyId,
            redeemerContext
        );

        require(redeemerBalance.storedPerpetualTokenBalance >= tokensToRedeem, "Insufficient tokens");
        redeemerBalance.netPerpetualTokenSupplyChange = tokensToRedeem.neg();

        (
            int totalAssetCash,
            bool hasResidual,
            PortfolioAsset[] memory newfCashAssets
        ) =  redeemPerpetualToken(currencyId, int(tokensToRedeem), sellTokenAssets, blockTime);
        redeemerBalance.netCashChange = totalAssetCash;

        if (hasResidual) {
            if (redeemerContext.bitmapCurrencyId == 0) {
                addResidualsToPortfolio(redeemer, redeemerContext, newfCashAssets, redeemerBalance);
            } else if (redeemerContext.bitmapCurrencyId == currencyId) {
                addResidualsToBitmap(redeemer, redeemerContext, newfCashAssets, redeemerBalance);
            } else {
                revert("Cannot redeem, residuals");
            }
        }

        redeemerBalance.finalize(redeemer, redeemerContext, false);
        redeemerContext.setAccountContext(redeemer);

        emit RedeemPerpetualToken(redeemer, currencyId, tokensToRedeem_);

        if (redeemerContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(redeemer);
        }
    }

    function redeemPerpetualToken(
        uint currencyId,
        int tokensToRedeem,
        bool sellTokenAssets,
        uint blockTime
    ) private returns (int, bool, PortfolioAsset[] memory) {
        int totalAssetCash;
        PortfolioAsset[] memory newfCashAssets;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(currencyId);
        // Get the assetCash and fCash assets as a result of redeeming perpetual tokens
        (newfCashAssets, totalAssetCash) = reducePerpetualTokenAssets(perpToken, tokensToRedeem, blockTime);

        // hasResidual is set to true if fCash assets need to be put back into the redeemer's portfolio
        bool hasResidual = true;
        if (sellTokenAssets) {
            int assetCash;
            (assetCash, hasResidual) = sellfCashAssets(
                perpToken.cashGroup,
                perpToken.markets,
                newfCashAssets,
                blockTime
            );

            totalAssetCash = totalAssetCash.add(assetCash);
        }

        // Finalize all market states
        for (uint i; i < perpToken.markets.length; i++) {
            perpToken.markets[i].setMarketStorage();
        }

        return (
            totalAssetCash,
            hasResidual,
            newfCashAssets
        );
    }

    /**
     * @notice Removes perpetual token assets and returns the net amount of asset cash owed to the account.
     */
    function reducePerpetualTokenAssets(
        PerpetualTokenPortfolio memory perpToken,
        int tokensToRedeem,
        uint blockTime
    ) internal returns (PortfolioAsset[] memory, int) {
        uint nextSettleTime = perpToken.getNextSettleTime();
        require(nextSettleTime > blockTime, "PT: requires settlement");

        // Get share of ifCash assets to remove
        PortfolioAsset[] memory newifCashAssets = BitmapAssetsHandler.reduceifCashAssetsProportional(
            perpToken.tokenAddress,
            perpToken.cashGroup.currencyId,
            perpToken.lastInitializedTime,
            tokensToRedeem,
            perpToken.totalSupply
        );

        // Get asset cash share for the perp token, if it exists. It is required in balance handler that the
        // perp token can never have a negative cash asset cash balance.
        int assetCashShare = perpToken.cashBalance.mul(tokensToRedeem).div(perpToken.totalSupply);
        if (assetCashShare > 0) {
            perpToken.cashBalance = perpToken.cashBalance.subNoNeg(assetCashShare);
            BalanceHandler.setBalanceStorageForPerpToken(perpToken.tokenAddress, perpToken.cashGroup.currencyId, perpToken.cashBalance);
        }

        // Get share of liquidity tokens to remove
        assetCashShare = assetCashShare.add(
            removeLiquidityTokens(
                perpToken,
                newifCashAssets,
                tokensToRedeem,
                perpToken.totalSupply,
                blockTime
            )
        );

        // Update perpetual token portfolio
        {
            (
                /* hasDebt */,
                /* currencies */,
                uint8 newStorageLength,
                /* nextSettleTime */
            ) = perpToken.portfolioState.storeAssets(perpToken.tokenAddress);
            // This can happen if a liquidity token is redeemed down to zero. It's possible that due to dust amounts
            // one token is reduced down to a zero balance while the others still have some amount remaining. In this case
            // the mint perpetual token will fail in `addLiquidityToMarket`
            // TODO: test and address this issue
            if (perpToken.portfolioState.storedAssets.length != uint(newStorageLength)) {
                PerpetualToken.setArrayLengthAndInitializedTime(
                    perpToken.tokenAddress,
                    newStorageLength,
                    perpToken.lastInitializedTime
                );
            }
        }

        // NOTE: Token supply change will happen when we finalize balances and after minting of incentives
        return (newifCashAssets, assetCashShare);
    }

    /**
     * @notice Removes perpetual token liquidity tokens and updates the netfCash figures.
     */
    function removeLiquidityTokens(
        PerpetualTokenPortfolio memory perpToken,
        PortfolioAsset[] memory newifCashAssets,
        int tokensToRedeem,
        int totalSupply,
        uint blockTime
    ) private view returns (int) {
        uint ifCashIndex;
        int totalAssetCash;

        for (uint i; i < perpToken.portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[i];
            int tokensToRemove = asset.notional.mul(tokensToRedeem).div(int(totalSupply));
            asset.notional = asset.notional.sub(tokensToRemove);
            asset.storageState = AssetStorageState.Update;

            perpToken.markets[i] = perpToken.cashGroup.getMarket(perpToken.markets, i + 1, blockTime, true);
            // Remove liquidity from the market
            (int assetCash, int fCash) = perpToken.markets[i].removeLiquidity(tokensToRemove);
            totalAssetCash = totalAssetCash.add(assetCash);

            // It is improbable but possible that an fcash asset does not exist if the fCash position for an active liquidity token
            // is zero. This would occur when the perpetual token has done a lot of lending instead of providing liquidity to the point
            // where the fCash position is exactly zero. This is highly unlikely so instead of adding more logic to handle it we will just
            // fail here. Minting some amount of perp tokens will cause the fCash position to be reinstated.
            while (newifCashAssets[ifCashIndex].maturity != asset.maturity) {
                ifCashIndex += 1;
                require(ifCashIndex < newifCashAssets.length, "Error removing tokens");
            }
            newifCashAssets[ifCashIndex].notional = newifCashAssets[ifCashIndex].notional.add(fCash);
        }

        return totalAssetCash;
    }

    /**
     * @notice Sells fCash assets back into the market for cash. Negative fCash assets will decrease netAssetCash
     * as a result. The aim here is to ensure that accounts can redeem perpetual tokens without having to take on
     * fCash assets.
     */
    function sellfCashAssets(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime
    ) private returns (int, bool) {
        int[] memory values = new int[](2);
        uint fCashIndex;
        bool hasResidual;

        for (uint i; i < markets.length; i++) {
            if (fCashAssets[fCashIndex].notional == 0) {
                fCashIndex += 1;
                continue;
            }

            while (fCashAssets[fCashIndex].maturity < markets[i].maturity) {
                // Skip an idiosyncratic fCash asset, if this happens then we know there is a residual
                // fCash asset
                fCashIndex += 1;
                hasResidual = true;
            }
            // It's not clear that this is idiosyncratic at this point
            if (fCashAssets[fCashIndex].maturity > markets[i].maturity) continue;

            (
                int netAssetCash,
                int fee
            ) = markets[i].calculateTrade(
                cashGroup,
                // Use the negative of fCash notional here since we want to net it out
                fCashAssets[fCashIndex].notional.neg(),
                fCashAssets[fCashIndex].maturity.sub(blockTime),
                i + 1
            );

            if (netAssetCash == 0) {
                // In this case the trade has failed and there will be some residual fCash
                hasResidual = true;
            } else {
                values[0] = values[0].add(netAssetCash);
                values[1] = values[1].add(fee);
                fCashAssets[fCashIndex].notional = 0;
            }

            fCashIndex += 1;
        }
        BalanceHandler.incrementFeeToReserve(cashGroup.currencyId, values[1]);

        // By the end of the for loop all fCashAssets should have been accounted for as traded, failed in trade,
        // or skipped and hasResidual is marked as true. It is not possible to have idiosyncratic fCash at a date
        // past the max market maturity since maxMarketIndex can never be reduced.
        return (values[0], hasResidual);
    }

    function addResidualsToPortfolio(
        address redeemer,
        AccountStorage memory redeemerContext,
        PortfolioAsset[] memory newfCashAssets,
        BalanceState memory balanceState
    ) private {
        PortfolioState memory portfolioState;
        if (redeemerContext.mustSettleAssets()) {
            SettleAmount[] memory settleAmounts;
            (
                redeemerContext,
                settleAmounts,
                portfolioState
            ) = SettleAssetsExternal.settleAssetsAndReturnPortfolio(redeemer);
            
            // Merge a cash change in the current currency into the balance state to save a storage write
            for (uint i; i < settleAmounts.length; i++) {
                if (settleAmounts[i].currencyId == balanceState.currencyId) {
                    balanceState.netCashChange = balanceState.netCashChange.add(settleAmounts[i].netCashChange);
                    settleAmounts[i].netCashChange = 0;
                    break;
                }
            }

            BalanceHandler.finalizeSettleAmounts(redeemer, redeemerContext, settleAmounts);
        } else {
            portfolioState = PortfolioHandler.buildPortfolioState(
                redeemer,
                redeemerContext.assetArrayLength,
                newfCashAssets.length
            );
        }

        portfolioState.addMultipleAssets(newfCashAssets);
        redeemerContext.storeAssetsAndUpdateContext(redeemer, portfolioState);
    }

    function addResidualsToBitmap(
        address redeemer,
        AccountStorage memory redeemerContext,
        PortfolioAsset[] memory newfCashAssets,
        BalanceState memory balanceState
    ) private {
        if (redeemerContext.mustSettleAssets()) {
            SettleAmount[] memory settleAmounts;
            (
                redeemerContext,
                settleAmounts
            ) = SettleAssetsExternal.settleAssetsAndStorePortfolio(redeemer);
            require(settleAmounts.length == 1 && settleAmounts[0].currencyId == balanceState.currencyId); // dev: invalid bitmap settlement
            // We know that settling assets will only result in the same currency as this one
            balanceState.netCashChange = balanceState.netCashChange.add(settleAmounts[0].netCashChange);
        }

        bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(redeemer, balanceState.currencyId);
        for (uint i; i < newfCashAssets.length; i++) {
            if (newfCashAssets[i].notional == 0) continue;
            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                redeemer,
                balanceState.currencyId,
                newfCashAssets[i].maturity,
                redeemerContext.nextSettleTime,
                newfCashAssets[i].notional,
                ifCashBitmap
            );
        }
        BitmapAssetsHandler.setAssetsBitmap(redeemer, balanceState.currencyId, ifCashBitmap);
    }
}