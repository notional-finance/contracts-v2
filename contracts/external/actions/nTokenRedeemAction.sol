// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/markets/Market.sol";
import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/nToken/nTokenCalculations.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/portfolio/TransferAssets.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library nTokenRedeemAction {
    using SafeInt256 for int256;
    using SafeMath for uint256;
    using Bitmap for bytes32;
    using BalanceHandler for BalanceState;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
    using PortfolioHandler for PortfolioState;
    using nTokenHandler for nTokenPortfolio;

    /// @notice When redeeming nTokens via the batch they must all be sold to cash and this
    /// method will return the amount of asset cash sold.
    /// @param currencyId the currency associated the nToken
    /// @param tokensToRedeem the amount of nTokens to convert to cash
    /// @return amount of asset cash to return to the account, denominated in internal token decimals
    function nTokenRedeemViaBatch(uint16 currencyId, int256 tokensToRedeem)
        external
        returns (int256)
    {
        uint256 blockTime = block.timestamp;
        // prettier-ignore
        (
            int256 totalAssetCash,
            bool hasResidual,
            /* PortfolioAssets[] memory newfCashAssets */
        ) = _redeem(currencyId, tokensToRedeem, true, false, blockTime);

        require(!hasResidual, "Cannot redeem via batch, residual");
        return totalAssetCash;
    }

    /// @notice Redeems nTokens for asset cash and fCash
    /// @param currencyId the currency associated the nToken
    /// @param tokensToRedeem the amount of nTokens to convert to cash
    /// @param sellTokenAssets attempt to sell residual fCash and convert to cash, if unsuccessful then place
    /// back into the account's portfolio
    /// @param acceptResidualAssets if true, then ifCash residuals will be placed into the account and there will
    /// be no penalty assessed
    /// @return assetCash positive amount of asset cash to the account
    /// @return hasResidual true if there are fCash residuals left
    /// @return assets an array of fCash asset residuals to place into the account
    function redeem(
        uint16 currencyId,
        int256 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets
    ) external returns (int256, bool, PortfolioAsset[] memory) {
        return _redeem(
            currencyId,
            tokensToRedeem,
            sellTokenAssets,
            acceptResidualAssets,
            block.timestamp
        );
    }

    function _redeem(
        uint16 currencyId,
        int256 tokensToRedeem,
        bool sellTokenAssets,
        bool acceptResidualAssets,
        uint256 blockTime
    ) internal returns (int256, bool, PortfolioAsset[] memory) {
        require(tokensToRedeem > 0);
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioStateful(currencyId);
        // nTokens cannot be redeemed during the period of time where they require settlement.
        require(nToken.getNextSettleTime() > blockTime, "Requires settlement");
        require(tokensToRedeem < nToken.totalSupply, "Cannot redeem");
        PortfolioAsset[] memory newifCashAssets;

        // Get the ifCash bits that are idiosyncratic
        bytes32 ifCashBits = nTokenCalculations.getNTokenifCashBits(
            nToken.tokenAddress,
            currencyId,
            nToken.lastInitializedTime,
            blockTime,
            nToken.cashGroup.maxMarketIndex
        );

        if (ifCashBits != 0 && acceptResidualAssets) {
            // This will remove all the ifCash assets proportionally from the account
            newifCashAssets = _reduceifCashAssetsProportional(
                nToken.tokenAddress,
                currencyId,
                nToken.lastInitializedTime,
                tokensToRedeem,
                nToken.totalSupply,
                ifCashBits
            );

            // Once the ifCash bits have been withdrawn, set this to zero so that getLiquidityTokenWithdraw
            // simply gets the proportional amount of liquidity tokens to remove
            ifCashBits = 0;
        }

        // Returns the liquidity tokens to withdraw per market and the netfCash amounts. Net fCash amounts are only
        // set when ifCashBits != 0. Otherwise they must be calculated in _withdrawLiquidityTokens
        (int256[] memory tokensToWithdraw, int256[] memory netfCash) = nTokenCalculations.getLiquidityTokenWithdraw(
            nToken,
            tokensToRedeem,
            blockTime,
            ifCashBits
        );

        // Returns the totalAssetCash as a result of withdrawing liquidity tokens and cash. netfCash will be updated
        // in memory if required and will contain the fCash to be sold or returned to the portfolio
        int256 totalAssetCash = _reduceLiquidAssets(
           nToken,
           tokensToRedeem,
           tokensToWithdraw,
           netfCash,
           ifCashBits == 0, // If there are no residuals then we need to populate netfCash amounts
           blockTime
        );

        bool netfCashRemaining = true;
        if (sellTokenAssets) {
            int256 assetCash;
            // NOTE: netfCash is modified in place and set to zero if the fCash is sold
            (assetCash, netfCashRemaining) = _sellfCashAssets(nToken, netfCash, blockTime);
            totalAssetCash = totalAssetCash.add(assetCash);
        }

        if (netfCashRemaining) {
            // If the account is unwilling to accept residuals then will fail here.
            newifCashAssets = _addResidualsToAssets(nToken.portfolioState.storedAssets, newifCashAssets, netfCash);
            require(acceptResidualAssets || newifCashAssets.length == 0, "Residuals");
        }

        return (totalAssetCash, netfCashRemaining, newifCashAssets);
    }

    /// @notice Removes liquidity tokens and cash from the nToken
    /// @param nToken portfolio object
    /// @param nTokensToRedeem tokens to redeem
    /// @param tokensToWithdraw array of liquidity tokens to withdraw
    /// @param netfCash array of netfCash figures
    /// @param mustCalculatefCash true if netfCash must be calculated in the removeLiquidityTokens step
    /// @param blockTime current block time
    /// @return assetCashShare amount of cash the redeemer will receive from withdrawing cash assets from the nToken
    function _reduceLiquidAssets(
        nTokenPortfolio memory nToken,
        int256 nTokensToRedeem,
        int256[] memory tokensToWithdraw,
        int256[] memory netfCash,
        bool mustCalculatefCash,
        uint256 blockTime
    ) private returns (int256 assetCashShare) {
        // Get asset cash share for the nToken, if it exists. It is required in balance handler that the
        // nToken can never have a negative cash asset cash balance so what we get here is always positive
        // or zero.
        assetCashShare = nToken.cashBalance.mul(nTokensToRedeem).div(nToken.totalSupply);
        if (assetCashShare > 0) {
            nToken.cashBalance = nToken.cashBalance.subNoNeg(assetCashShare);
            BalanceHandler.setBalanceStorageForNToken(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                nToken.cashBalance
            );
        }

        // Get share of liquidity tokens to remove, netfCash is modified in memory during this method if mustCalculatefcash
        // is set to true
        assetCashShare = assetCashShare.add(
            _removeLiquidityTokens(nToken, nTokensToRedeem, tokensToWithdraw, netfCash, blockTime, mustCalculatefCash)
        );

        nToken.portfolioState.storeAssets(nToken.tokenAddress);

        // NOTE: Token supply change will happen when we finalize balances and after minting of incentives
        return assetCashShare;
    }

    /// @notice Removes nToken liquidity tokens and updates the netfCash figures.
    /// @param nToken portfolio object
    /// @param nTokensToRedeem tokens to redeem
    /// @param tokensToWithdraw array of liquidity tokens to withdraw
    /// @param netfCash array of netfCash figures
    /// @param blockTime current block time
    /// @param mustCalculatefCash true if netfCash must be calculated in the removeLiquidityTokens step
    /// @return totalAssetCashClaims is the amount of asset cash raised from liquidity token cash claims
    function _removeLiquidityTokens(
        nTokenPortfolio memory nToken,
        int256 nTokensToRedeem,
        int256[] memory tokensToWithdraw,
        int256[] memory netfCash,
        uint256 blockTime,
        bool mustCalculatefCash
    ) private returns (int256 totalAssetCashClaims) {
        MarketParameters memory market;

        for (uint256 i = 0; i < nToken.portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = nToken.portfolioState.storedAssets[i];
            asset.notional = asset.notional.sub(tokensToWithdraw[i]);
            // Cannot redeem liquidity tokens down to zero or this will cause many issues with
            // market initialization.
            require(asset.notional > 0, "Cannot redeem to zero");
            require(asset.storageState == AssetStorageState.NoChange);
            asset.storageState = AssetStorageState.Update;

            // This will load a market object in memory
            nToken.cashGroup.loadMarket(market, i + 1, true, blockTime);
            int256 fCashClaim;
            {
                int256 assetCash;
                // Remove liquidity from the market
                (assetCash, fCashClaim) = market.removeLiquidity(tokensToWithdraw[i]);
                totalAssetCashClaims = totalAssetCashClaims.add(assetCash);
            }

            int256 fCashToNToken;
            if (mustCalculatefCash) {
                // Do this calculation if net ifCash is not set, will happen if there are no residuals
                int256 fCashShare = BitmapAssetsHandler.getifCashNotional(
                    nToken.tokenAddress,
                    nToken.cashGroup.currencyId,
                    asset.maturity
                );
                fCashShare = fCashShare.mul(nTokensToRedeem).div(nToken.totalSupply);
                // netfCash = fCashClaim + fCashShare
                netfCash[i] = fCashClaim.add(fCashShare);
                fCashToNToken = fCashShare.neg();
            } else {
                // Account will receive netfCash amount. Deduct that from the fCash claim and add the
                // remaining back to the nToken to net off the nToken's position
                // fCashToNToken = -fCashShare
                // netfCash = fCashClaim + fCashShare
                // fCashToNToken = -(netfCash - fCashClaim)
                // fCashToNToken = fCashClaim - netfCash
                fCashToNToken = fCashClaim.sub(netfCash[i]);
            }

            // Removes the account's fCash position from the nToken
            BitmapAssetsHandler.addifCashAsset(
                nToken.tokenAddress,
                asset.currencyId,
                asset.maturity,
                nToken.lastInitializedTime,
                fCashToNToken
            );
        }

        return totalAssetCashClaims;
    }

    /// @notice Sells fCash assets back into the market for cash. Negative fCash assets will decrease netAssetCash
    /// as a result. The aim here is to ensure that accounts can redeem nTokens without having to take on
    /// fCash assets.
    function _sellfCashAssets(
        nTokenPortfolio memory nToken,
        int256[] memory netfCash,
        uint256 blockTime
    ) private returns (int256 totalAssetCash, bool hasResidual) {
        MarketParameters memory market;
        hasResidual = false;

        for (uint256 i = 0; i < netfCash.length; i++) {
            if (netfCash[i] == 0) continue;

            nToken.cashGroup.loadMarket(market, i + 1, false, blockTime);
            int256 netAssetCash = market.executeTrade(
                nToken.cashGroup,
                // Use the negative of fCash notional here since we want to net it out
                netfCash[i].neg(),
                nToken.portfolioState.storedAssets[i].maturity.sub(blockTime),
                i + 1
            );

            if (netAssetCash == 0) {
                // This means that the trade failed
                hasResidual = true;
            } else {
                totalAssetCash = totalAssetCash.add(netAssetCash);
                netfCash[i] = 0;
            }
        }
    }

    /// @notice Combines newifCashAssets array with netfCash assets into a single finalfCashAssets array
    function _addResidualsToAssets(
        PortfolioAsset[] memory liquidityTokens,
        PortfolioAsset[] memory newifCashAssets,
        int256[] memory netfCash
    ) internal pure returns (PortfolioAsset[] memory finalfCashAssets) {
        uint256 numAssetsToExtend;
        for (uint256 i = 0; i < netfCash.length; i++) {
            if (netfCash[i] != 0) numAssetsToExtend++;
        }

        uint256 newLength = newifCashAssets.length + numAssetsToExtend;
        finalfCashAssets = new PortfolioAsset[](newLength);
        uint index = 0;
        for (; index < newifCashAssets.length; index++) {
            finalfCashAssets[index] = newifCashAssets[index];
        }

        uint netfCashIndex = 0;
        for (; index < finalfCashAssets.length; ) {
            if (netfCash[netfCashIndex] != 0) {
                PortfolioAsset memory asset = finalfCashAssets[index];
                asset.currencyId = liquidityTokens[netfCashIndex].currencyId;
                asset.maturity = liquidityTokens[netfCashIndex].maturity;
                asset.assetType = Constants.FCASH_ASSET_TYPE;
                asset.notional = netfCash[netfCashIndex];
                index++;
            }

            netfCashIndex++;
        }

        return finalfCashAssets;
    }

    /// @notice Used to reduce an nToken ifCash assets portfolio proportionately when redeeming
    /// nTokens to its underlying assets.
    function _reduceifCashAssetsProportional(
        address account,
        uint256 currencyId,
        uint256 lastInitializedTime,
        int256 tokensToRedeem,
        int256 totalSupply,
        bytes32 assetsBitmap
    ) internal returns (PortfolioAsset[] memory) {
        uint256 index = assetsBitmap.totalBitsSet();
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();

        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(lastInitializedTime, bitNum);
            ifCashStorage storage fCashSlot = store[account][currencyId][maturity];
            int256 notional = fCashSlot.notional;

            int256 notionalToTransfer = notional.mul(tokensToRedeem).div(totalSupply);
            int256 finalNotional = notional.sub(notionalToTransfer);

            require(type(int128).min <= finalNotional && finalNotional <= type(int128).max); // dev: bitmap notional overflow
            fCashSlot.notional = int128(finalNotional);

            PortfolioAsset memory asset = assets[index];
            asset.currencyId = currencyId;
            asset.maturity = maturity;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = notionalToTransfer;
            index += 1;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        return assets;
    }
}
