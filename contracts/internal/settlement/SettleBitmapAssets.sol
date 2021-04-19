// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../markets/AssetRate.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";

library SettleBitmapAssets {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Bitmap for bytes32;

    /// @notice Stateful settlement function to settle a bitmapped asset. Deletes the
    /// asset from storage after calculating it.
    function _settleBitmappedAsset(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        uint256 bitNum,
        bytes32 bits
    ) private returns (bytes32, int256) {
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
        // prettier-ignore
        (
            uint256 lastSettleBit,
            /* isValid */
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
                (splitBitmap.dayBits, assetCash) = _settleBitmappedAsset(
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
                (splitBitmap.weekBits, assetCash) = _settleBitmappedAsset(
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
                (splitBitmap.monthBits, assetCash) = _settleBitmappedAsset(
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
                (splitBitmap.quarterBits, assetCash) = _settleBitmappedAsset(
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

        _remapBitmap(splitBitmap, nextSettleTime, blockTimeUTC0, lastSettleBit);
        bitmap = Bitmap.combineAssetBitmap(splitBitmap);

        return (bitmap, totalAssetCash);
    }

    /// @notice Remaps bitmap bits from higher time chunks to lower time chunks
    /// @dev Marked as internal rather than private so we can mock and test directly
    function _remapBitmap(
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
        uint256 timeChunkTimeLength,
        SplitBitmap memory splitBitmap,
        bytes32 bits
    ) private pure returns (bytes32) {
        // The first bit of the section is just above the bitOffset
        uint256 firstBitMaturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitOffset + 1);
        uint256 newFirstBitMaturity = DateTime.getMaturityFromBitNum(blockTimeUTC0, bitOffset + 1);
        // NOTE: this will truncate the decimals
        uint256 bitsToShift = (newFirstBitMaturity - firstBitMaturity) / timeChunkTimeLength;

        for (uint256 i; i < bitsToShift; i++) {
            if (bits == 0x00) break;

            if ((bits & Constants.MSB) == Constants.MSB) {
                // Map this into the lower section of the bitmap
                uint256 maturity = firstBitMaturity + i * timeChunkTimeLength;
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
