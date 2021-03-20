// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Market.sol";
import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "../storage/TokenHandler.sol";
import "./FreeCollateralExternal.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library RedeemPerpetualTokenAction {
    using SafeInt256 for int;
    using SafeMath for uint;
    using BalanceHandler for BalanceState;
    using TokenHandler for Token;
    using Market for MarketParameters;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;

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
        ) =  _redeemPerpetualToken(currencyId, tokensToRedeem, true, blockTime);

        require(!hasResidual, "Cannot redeem via batch, residual");
        return totalAssetCash;
    }

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
        ) =  _redeemPerpetualToken(currencyId, int(tokensToRedeem), sellTokenAssets, blockTime);

        redeemerBalance.netCashChange = totalAssetCash;

        if (hasResidual) {
            // For simplicity's sake, you cannot redeem tokens if your portfolio must be settled.
            require(
                redeemerContext.nextMaturingAsset == 0 || redeemerContext.nextMaturingAsset > blockTime,
                "RP: must settle portfolio"
            );

            PortfolioState memory redeemerPortfolio = PortfolioHandler.buildPortfolioState(
                redeemer,
                redeemerContext.assetArrayLength,
                newfCashAssets.length
            );

            // TODO: handle bitmaps, check if hasDebt
            for (uint i; i < newfCashAssets.length; i++) {
                if (newfCashAssets[i].notional == 0) continue;

                redeemerPortfolio.addAsset(
                    newfCashAssets[i].currencyId,
                    newfCashAssets[i].maturity,
                    newfCashAssets[i].assetType,
                    newfCashAssets[i].notional,
                    false
                );
            }

            redeemerContext.storeAssetsAndUpdateContext(redeemer, redeemerPortfolio);
        }

        redeemerBalance.finalize(redeemer, redeemerContext, false);
        redeemerContext.setAccountContext(redeemer);

        // TODO: must free collateral check here if recipient is keeping LTs
        if (redeemerContext.hasDebt) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(redeemer);
        }
    }

    function _redeemPerpetualToken(
        uint currencyId,
        int tokensToRedeem,
        bool sellTokenAssets,
        uint blockTime
    ) internal returns (int, bool, PortfolioAsset[] memory) {
        int totalAssetCash;
        PortfolioAsset[] memory newfCashAssets;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(currencyId);
        {
            // Get the assetCash and fCash assets as a result of redeeming perpetual tokens
            AccountStorage memory perpTokenContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);
            (newfCashAssets, totalAssetCash) = PerpetualToken.redeemPerpetualToken(
                perpToken,
                perpTokenContext,
                tokensToRedeem,
                blockTime
            );
        }

        // hasResidual is set to true if fCash assets need to be put back into the redeemer's portfolio
        bool hasResidual = true;
        if (sellTokenAssets) {
            int assetCash;
            (assetCash, hasResidual) = _sellfCashAssets(
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
     * @notice Sells fCash assets back into the market for cash. Negative fCash assets will decrease netAssetCash
     * as a result. Since the perpetual token is never undercollateralized it should be that totalAssetCash is
     * always positive.
     */
    function _sellfCashAssets(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime
    ) internal view returns (int, bool) {
        int totalAssetCash;
        uint fCashIndex;
        bool hasResidual;

        for (uint i; i < markets.length; i++) {
            while (fCashAssets[fCashIndex].maturity < markets[i].maturity) {
                // Skip an idiosyncratic fCash asset, if this happens then we know there is a residual
                // fCash asset
                fCashIndex += 1;
                hasResidual = true;
            }
            // It's not clear that this is idiosyncratic at this point
            if (fCashAssets[fCashIndex].maturity > markets[i].maturity) continue;

            uint timeToMaturity = fCashAssets[fCashIndex].maturity.sub(blockTime);
            int netAssetCash = markets[i].calculateTrade(
                cashGroup,
                // TODO: should this be negative?
                fCashAssets[fCashIndex].notional,
                timeToMaturity,
                i + 1
            );

            if (netAssetCash == 0) {
                // In this case the trade has failed and there will be some residual fCash
                hasResidual = true;
            } else {
                totalAssetCash = netAssetCash.add(netAssetCash);
                fCashAssets[fCashIndex].notional = 0;
            }

            fCashIndex += 1;
        }

        // By the end of the for loop all fCashAssets should have been accounted for as traded, failed in trade,
        // or skipped and hasResidual is marked as true. It is not possible to have idiosyncratic fCash at a date
        // past the max market maturity since maxMarketIndex can never be reduced.
        return (totalAssetCash, hasResidual);
    }

}