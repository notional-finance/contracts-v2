// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../valuation/AssetHandler.sol";
import "../markets/AssetRate.sol";
import "../portfolio/PortfolioHandler.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";

library SettleAssets {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Bitmap for bytes32;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;

    function getSettleAmountArray(PortfolioState memory portfolioState, uint256 blockTime)
        internal
        pure
        returns (SettleAmount[] memory)
    {
        uint256 currenciesSettled;
        uint256 lastCurrencyId;
        if (portfolioState.storedAssets.length == 0) return new SettleAmount[](0);

        // Loop backwards so "lastCurrencyId" will be set to the first currency in the portfolio
        for (uint256 i = portfolioState.storedAssets.length - 1; i >= 0; i--) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.getSettlementDate() > blockTime) {
                if (i == 0) break;
                continue;
            }

            // Assume that this is sorted by cash group and maturity, currencyId = 0 is unused so this
            // will work for the first asset
            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                currenciesSettled++;
            }

            // i-- will overflow and end up with index out of bounds error
            if (i == 0) break;
        }

        // Actual currency ids will be set in the loop
        SettleAmount[] memory settleAmounts = new SettleAmount[](currenciesSettled);
        if (currenciesSettled > 0) settleAmounts[0].currencyId = lastCurrencyId;
        return settleAmounts;
    }

    /// @notice Shared calculation for liquidity token settlement

    function calculateMarketStorage(PortfolioAsset memory asset)
        internal
        view
        returns (
            int256,
            int256,
            SettlementMarket memory
        )
    {
        // 2x Storage Read
        SettlementMarket memory market =
            Market.getSettlementMarket(asset.currencyId, asset.maturity, asset.getSettlementDate());

        int256 fCash = int256(market.totalfCash).mul(asset.notional).div(market.totalLiquidity);
        int256 cashClaim =
            int256(market.totalCurrentCash).mul(asset.notional).div(market.totalLiquidity);

        require(fCash <= market.totalfCash); // dev: settle liquidity token totalfCash overflow
        require(cashClaim <= market.totalCurrentCash); // dev: settle liquidity token totalCurrentCash overflow
        require(asset.notional <= market.totalLiquidity); // dev: settle liquidity token total liquidity overflow
        market.totalfCash = market.totalfCash - fCash;
        market.totalCurrentCash = market.totalCurrentCash - cashClaim;
        market.totalLiquidity = market.totalLiquidity - asset.notional;

        return (cashClaim, fCash, market);
    }

    /// @notice Settles a liquidity token which requires getting the claims on both cash and fCash,
    /// converting the fCash portion to cash at the settlement rate.

    function settleLiquidityToken(
        PortfolioAsset memory asset,
        AssetRateParameters memory settlementRate
    ) internal view returns (int256, SettlementMarket memory) {
        (int256 cashClaim, int256 fCash, SettlementMarket memory market) =
            calculateMarketStorage(asset);

        int256 assetCash = cashClaim.add(settlementRate.convertFromUnderlying(fCash));

        return (assetCash, market);
    }

    /// @notice Settles a liquidity token to idiosyncratic fCash

    function settleLiquidityTokenTofCash(PortfolioState memory portfolioState, uint256 index)
        internal
        view
        returns (int256, SettlementMarket memory)
    {
        PortfolioAsset memory liquidityToken = portfolioState.storedAssets[index];
        (int256 cashClaim, int256 fCash, SettlementMarket memory market) =
            calculateMarketStorage(liquidityToken);

        // If the liquidity token's maturity is still in the future then we change the entry to be
        // an idiosyncratic fCash entry with the net fCash amount.
        if (index != 0) {
            // Check to see if the previous index is the matching fCash asset, this would be the case when the
            // portfolio is sorted
            PortfolioAsset memory fCashAsset = portfolioState.storedAssets[index - 1];

            if (
                fCashAsset.maturity == liquidityToken.maturity &&
                fCashAsset.assetType == Constants.FCASH_ASSET_TYPE
            ) {
                // This fCash asset will not have matured if were are settling to fCash
                fCashAsset.notional = fCashAsset.notional.add(fCash);
                fCashAsset.storageState = AssetStorageState.Update;

                portfolioState.deleteAsset(index);
                return (cashClaim, market);
            }
        }

        liquidityToken.assetType = Constants.FCASH_ASSET_TYPE;
        liquidityToken.notional = fCash;
        liquidityToken.storageState = AssetStorageState.Update;

        return (cashClaim, market);
    }

    /// @notice View version of settle asset with a call to getSettlementRateView, the reason here is that
    /// in the stateful version we will set the settlement rate if it is not set.

    function getSettleAssetContextView(PortfolioState memory portfolioState, uint256 blockTime)
        internal
        view
        returns (SettleAmount[] memory)
    {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = getSettleAmountArray(portfolioState, blockTime);
        if (settleAmounts.length == 0) return settleAmounts;
        uint256 settleAmountIndex;
        uint256 lastMaturity;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.getSettlementDate() > blockTime) continue;

            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                lastMaturity = 0;
                settleAmountIndex += 1;
                require(settleAmountIndex < settleAmounts.length); // dev: settle amount index
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            // Settlement rates are used to convert fCash and fCash claims back into assetCash values. This means
            // that settlement rates are required whenever fCash matures and when liquidity tokens' **fCash claims**
            // mature. fCash claims on liquidity tokens settle at asset.maturity, not the settlement date
            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read inside getSettlementRateView
                settlementRate = AssetRate.buildSettlementRateView(
                    asset.currencyId,
                    asset.maturity
                );
                lastMaturity = asset.maturity;
            }

            int256 assetCash;
            if (asset.assetType == Constants.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertFromUnderlying(asset.notional);
                portfolioState.deleteAsset(i);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                if (asset.maturity > blockTime) {
                    (
                        assetCash, /* */

                    ) = settleLiquidityTokenTofCash(portfolioState, i);
                } else {
                    (
                        assetCash, /* */

                    ) = settleLiquidityToken(asset, settlementRate);
                    portfolioState.deleteAsset(i);
                }
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex]
                .netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }

    /// @notice Stateful version of settle asset, the only difference is the call to getSettlementRateStateful

    function getSettleAssetContextStateful(PortfolioState memory portfolioState, uint256 blockTime)
        internal
        returns (SettleAmount[] memory)
    {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = getSettleAmountArray(portfolioState, blockTime);
        if (settleAmounts.length == 0) return settleAmounts;
        uint256 settleAmountIndex;
        uint256 lastMaturity;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.getSettlementDate() > blockTime) continue;

            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                lastMaturity = 0;
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read / Write inside getSettlementRateStateful
                settlementRate = AssetRate.buildSettlementRateStateful(
                    asset.currencyId,
                    asset.maturity,
                    blockTime
                );
                lastMaturity = asset.maturity;
            }

            int256 assetCash;
            if (asset.assetType == Constants.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertFromUnderlying(asset.notional);
                portfolioState.deleteAsset(i);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                SettlementMarket memory market;
                if (asset.maturity > blockTime) {
                    (assetCash, market) = settleLiquidityTokenTofCash(portfolioState, i);
                } else {
                    (assetCash, market) = settleLiquidityToken(asset, settlementRate);
                    portfolioState.deleteAsset(i);
                }

                // 2x storage write
                Market.setSettlementMarket(market);
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex]
                .netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }

    /// @notice Stateful settlement function to settle a bitmapped asset. Deletes the
    /// asset from storage after calculating it.

    function settleBitmappedAsset(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        uint256 bitNum,
        bytes32 bits
    ) internal returns (bytes32, int256) {
        int256 assetCash;

        if ((bits & Constants.MSB) == Constants.MSB) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            // Storage Read
            bytes32 ifCashSlot = BitmapAssetsHandler.getifCashSlot(account, currencyId, maturity);
            int256 ifCash;
            assembly {
                ifCash := sload(ifCashSlot)
            }

            // Storage Read / Write
            AssetRateParameters memory rate =
                AssetRate.buildSettlementRateStateful(currencyId, maturity, blockTime);
            assetCash = rate.convertFromUnderlying(ifCash);
            // Storage Delete
            assembly {
                sstore(ifCashSlot, 0)
            }
        }

        bits = bits << 1;

        return (bits, assetCash);
    }

    /// @notice Given a bitmap for a cash group and timestamps, will settle all assets
    /// that have matured and remap the bitmap to correspond to the current time.

    function settleBitmappedCashGroup(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime
    ) internal returns (bytes32, int256) {
        bytes32 bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);

        int256 totalAssetCash;
        SplitBitmap memory splitBitmap = bitmap.splitAssetBitmap();
        uint256 blockTimeUTC0 = DateTime.getTimeUTC0(blockTime);
        // This blockTimeUTC0 will be set to the new "nextSettleTime", this will refer to the
        // new next bit
        (
            uint256 lastSettleBit, /* isValid */

        ) = DateTime.getBitNumFromMaturity(nextSettleTime, blockTimeUTC0);
        if (lastSettleBit == 0) return (bitmap, totalAssetCash);

        // NOTE: bitNum is 1-indexed
        for (uint256 bitNum = 1; bitNum <= lastSettleBit; bitNum++) {
            if (bitNum <= Constants.WEEK_BIT_OFFSET) {
                if (splitBitmap.dayBits == 0x00) {
                    // No more bits set in day bits, continue to the next set of bits
                    bitNum = Constants.WEEK_BIT_OFFSET;
                    continue;
                }

                int256 assetCash;
                (splitBitmap.dayBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextSettleTime,
                    blockTime,
                    bitNum,
                    splitBitmap.dayBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            if (bitNum <= Constants.MONTH_BIT_OFFSET) {
                if (splitBitmap.weekBits == 0x00) {
                    bitNum = Constants.MONTH_BIT_OFFSET;
                    continue;
                }

                int256 assetCash;
                (splitBitmap.weekBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextSettleTime,
                    blockTime,
                    bitNum,
                    splitBitmap.weekBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            if (bitNum <= Constants.QUARTER_BIT_OFFSET) {
                if (splitBitmap.monthBits == 0x00) {
                    bitNum = Constants.QUARTER_BIT_OFFSET;
                    continue;
                }

                int256 assetCash;
                (splitBitmap.monthBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextSettleTime,
                    blockTime,
                    bitNum,
                    splitBitmap.monthBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }

            // Check 1-indexing here
            if (bitNum <= 256) {
                if (splitBitmap.quarterBits == 0x00) {
                    break;
                }

                int256 assetCash;
                (splitBitmap.quarterBits, assetCash) = settleBitmappedAsset(
                    account,
                    currencyId,
                    nextSettleTime,
                    blockTime,
                    bitNum,
                    splitBitmap.quarterBits
                );
                totalAssetCash = totalAssetCash.add(assetCash);
                continue;
            }
        }

        remapBitmap(splitBitmap, nextSettleTime, blockTimeUTC0, lastSettleBit);
        bitmap = Bitmap.combineAssetBitmap(splitBitmap);

        return (bitmap, totalAssetCash);
    }

    function remapBitmap(
        SplitBitmap memory splitBitmap,
        uint256 nextSettleTime,
        uint256 blockTimeUTC0,
        uint256 lastSettleBit
    ) internal pure {
        if (splitBitmap.weekBits != 0x00 && lastSettleBit < Constants.MONTH_BIT_OFFSET) {
            // Ensures that if part of the week portion is settled we still remap the remaining part
            // starting from the lastSettleBit. Skips if the lastSettleBit is past the offset
            uint256 bitOffset =
                lastSettleBit > Constants.WEEK_BIT_OFFSET
                    ? lastSettleBit
                    : Constants.WEEK_BIT_OFFSET;
            splitBitmap.weekBits = remapBitSection(
                nextSettleTime,
                blockTimeUTC0,
                bitOffset,
                Constants.WEEK,
                splitBitmap,
                splitBitmap.weekBits
            );
        }

        if (splitBitmap.monthBits != 0x00 && lastSettleBit < Constants.QUARTER_BIT_OFFSET) {
            uint256 bitOffset =
                lastSettleBit > Constants.MONTH_BIT_OFFSET
                    ? lastSettleBit
                    : Constants.MONTH_BIT_OFFSET;
            splitBitmap.monthBits = remapBitSection(
                nextSettleTime,
                blockTimeUTC0,
                bitOffset,
                Constants.MONTH,
                splitBitmap,
                splitBitmap.monthBits
            );
        }

        if (splitBitmap.quarterBits != 0x00 && lastSettleBit < 256) {
            uint256 bitOffset =
                lastSettleBit > Constants.QUARTER_BIT_OFFSET
                    ? lastSettleBit
                    : Constants.QUARTER_BIT_OFFSET;
            splitBitmap.quarterBits = remapBitSection(
                nextSettleTime,
                blockTimeUTC0,
                bitOffset,
                Constants.QUARTER,
                splitBitmap,
                splitBitmap.quarterBits
            );
        }
    }

    /// @dev Given a section of the bitmap, will remap active bits to a lower part of the bitmap.

    function remapBitSection(
        uint256 nextSettleTime,
        uint256 blockTimeUTC0,
        uint256 bitOffset,
        uint256 bitTimeLength,
        SplitBitmap memory splitBitmap,
        bytes32 bits
    ) internal pure returns (bytes32) {
        // The first bit of the section is just above the bitOffset
        uint256 firstBitRef = DateTime.getMaturityFromBitNum(nextSettleTime, bitOffset + 1);
        uint256 newFirstBitRef = DateTime.getMaturityFromBitNum(blockTimeUTC0, bitOffset + 1);
        // NOTE: this will truncate the decimals
        uint256 bitsToShift = (newFirstBitRef - firstBitRef) / bitTimeLength;

        for (uint256 i; i < bitsToShift; i++) {
            if (bits == 0x00) break;

            if ((bits & Constants.MSB) == Constants.MSB) {
                // Map this into the lower section of the bitmap
                uint256 maturity = firstBitRef + i * bitTimeLength;
                (uint256 newBitNum, bool isValid) =
                    DateTime.getBitNumFromMaturity(blockTimeUTC0, maturity);
                require(isValid); // dev: remap bit section invalid maturity

                if (newBitNum <= Constants.WEEK_BIT_OFFSET) {
                    // Shifting down into the day bits
                    bytes32 bitMask = Constants.MSB >> (newBitNum - 1);
                    splitBitmap.dayBits = splitBitmap.dayBits | bitMask;
                } else if (newBitNum <= Constants.MONTH_BIT_OFFSET) {
                    // Shifting down into the week bits
                    bytes32 bitMask = Constants.MSB >> (newBitNum - Constants.WEEK_BIT_OFFSET - 1);
                    splitBitmap.weekBits = splitBitmap.weekBits | bitMask;
                } else if (newBitNum <= Constants.QUARTER_BIT_OFFSET) {
                    // Shifting down into the month bits
                    bytes32 bitMask = Constants.MSB >> (newBitNum - Constants.MONTH_BIT_OFFSET - 1);
                    splitBitmap.monthBits = splitBitmap.monthBits | bitMask;
                } else {
                    revert(); // dev: remap bit section error in bit shift
                }
            }

            bits = bits << 1;
        }

        return bits;
    }
}
