// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Market.sol";
import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "../storage/TokenHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RedeemPerpetualTokenAction is StorageLayoutV1, ReentrancyGuard {
    using SafeInt256 for int;
    using SafeMath for uint;
    using BalanceHandler for BalanceState;
    using TokenHandler for Token;
    using Market for MarketParameters;
    using PortfolioHandler for PortfolioState;

    function perpetualTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem,
        bool sellTokenAssets
    ) external nonReentrant {
        return _redeemPerpetualToken(currencyId, msg.sender, int(tokensToRedeem), sellTokenAssets);
    }

    function _redeemPerpetualToken(
        uint currencyId,
        address redeemer,
        int tokensToRedeem,
        bool sellTokenAssets
    ) internal {
        if (tokensToRedeem == 0) return;
        uint blockTime = block.timestamp;

        AccountStorage memory redeemerContext = accountContextMapping[redeemer];
        BalanceState memory redeemerBalance = BalanceHandler.buildBalanceState(
            redeemer, 
            currencyId,
            redeemerContext
        );

        require(redeemerBalance.storedPerpetualTokenBalance >= tokensToRedeem, "Insufficient tokens");
        redeemerBalance.netPerpetualTokenTransfer = tokensToRedeem.neg();

        PortfolioAsset[] memory newfCashAssets;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        {
            // Get the assetCash and fCash assets as a result of redeeming perpetual tokens
            AccountStorage memory perpTokenContext = accountContextMapping[perpToken.tokenAddress];
            require(perpTokenContext.nextMaturingAsset < blockTime, "RP: requires settlement");

            (newfCashAssets, redeemerBalance.netCashChange) = PerpetualToken.redeemPerpetualToken(
                perpToken,
                perpTokenContext,
                assetArrayMapping[perpToken.tokenAddress],
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

            redeemerBalance.netCashChange = redeemerBalance.netCashChange.add(assetCash);
        }

        if (hasResidual) {
            // For simplicity's sake, you cannot redeem tokens if your portfolio must be settled.
            require(
                redeemerContext.nextMaturingAsset == 0 || redeemerContext.nextMaturingAsset > blockTime,
                "RP: must settle portfolio"
            );

            PortfolioState memory redeemerPortfolio = PortfolioHandler.buildPortfolioState(
                redeemer,
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

            // TODO: this needs to check if has debt and also update context
            redeemerPortfolio.storeAssets(assetArrayMapping[redeemer]);
        }

        // Finalize all market states
        for (uint i; i < perpToken.markets.length; i++) {
            perpToken.markets[i].setMarketStorage(AssetHandler.getSettlementDateViaAssetType(
                2 + i,
                perpToken.markets[i].maturity
            ));
        }

        redeemerBalance.finalize(redeemer, redeemerContext, false);
        accountContextMapping[redeemer] = redeemerContext;

        // TODO: must free collateral check here if recipient is keeping LTs
        if (redeemerContext.hasDebt) {
            revert("UNIMPLMENTED");
        }
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
    ) internal returns (int, bool) {
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
                fCashAssets[fCashIndex].notional,
                timeToMaturity
            );

            if (netAssetCash == 0) {
                // In this case the trade has failed and there will be some residual fCash
                hasResidual = true;
            } else {
                totalAssetCash = netAssetCash.add(netAssetCash);
                fCashAssets[fCashIndex].notional = 0;
            }
        }

        // By the end of the for loop all fCashAssets should have been accounted for as traded, failed in trade,
        // or skipped and hasResidual is marked as true. It is not possible to have idiosyncratic fCash at a date
        // past the max market maturity since maxMarketIndex can never be reduced.

        return (totalAssetCash, hasResidual);
    }

}