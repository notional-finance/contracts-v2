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
        // This blockTimeUTC0 will be set to the new `nextSettleTime`. The bits between 1 and
        // `lastSettleBit` will be shifted out of the bitmap and settled.
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
                // The loop will enter `_settleBitmappedAsset` every time and check
                // if the bit needs to be settled (if it is set or not). This method call
                // will also shift `dayBits` by one bit during each loop.
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

    /// @notice Remaps bitmap bits from higher time chunks to lower time chunks. When we have settled
    /// out of part of a bitmap, bits in higher time chunks may need to be remapped down to lower time.
    /// chunks.
    /// @dev Marked as internal rather than private so we can mock and test directly
    function _remapBitmap(
        SplitBitmap memory splitBitmap,
        uint256 nextSettleTime,
        uint256 blockTimeUTC0,
        uint256 lastSettleBit
    ) internal pure {
        // If there are no week bits set or if the method has settled through the entire week bit section (this
        // will happen when lastSettleBit >= MONTH_BIT_OFFSET) then no need to remap. See that MONTH_BIT_OFFSET
        // also represents the last bit number in the week bit chunks.
        if (splitBitmap.weekBits != 0x00 && lastSettleBit < Constants.MONTH_BIT_OFFSET) {
            // Bit offset is the (first bit - 1) that we should be remapping from. Bits less than 
            // or equal to lastSettleBit have been settled and therefore do not need to be remapped.
            // This if statement says:
            //  - WEEK_BIT_OFFSET < lastSettleBit < MONTH_BIT_OFFSET then start from lastSettleBit
            // else we know (given the if branch above):
            //  - lastSettleBit <= WEEK_BIT_OFFSET then we start from WEEK_BIT_OFFSET
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

    /// @dev Given a section of the bitmap, will remap active bits to a lower part of the bitmap. The
    /// bits may move down from any higher time chunk to any lower time chunk (they may move from the
    /// QUARTER time chunk all the way down to the DAY time chunk for example if a long time has lapsed
    /// between settlements).
    function remapBitSection(
        uint256 nextSettleTime,
        uint256 blockTimeUTC0,
        uint256 bitOffset,
        uint256 timeChunkTimeLength,
        SplitBitmap memory splitBitmap,
        bytes32 bits
    ) private pure returns (bytes32) {
        // The first bit of the section is just above the bitOffset. When bitOffset is set to one of the
        // constants WEEK_BIT_OFFSET, MONTH_BIT_OFFSET, QUARTER_BIT_OFFSET, this is still true.
        uint256 firstBitMaturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitOffset + 1);
        uint256 newFirstBitMaturity = DateTime.getMaturityFromBitNum(blockTimeUTC0, bitOffset + 1);
        // `bitsToRemap` refers to the number of bits inside the given section (weeks, months or quarters)
        // that need to be remapped down to a lower time section. These bits are defined by the number of
        // bits that will shift to the left as a result of the time lapsed between the last time the account
        // was settled and the current time.
        uint256 bitsToRemap = (newFirstBitMaturity - firstBitMaturity) / timeChunkTimeLength;

        for (uint256 i; i < bitsToRemap; i++) {
            if (bits == 0x00) break;

            if ((bits & Constants.MSB) == Constants.MSB) {
                // Shorter version of calculating maturity based on the firstBitMaturity.
                uint256 maturity = firstBitMaturity + i * timeChunkTimeLength;
                // Get the new bit number that this maturity should be at given the current
                // block time. This should always be valid but we double check to be defensive.
                (uint256 newBitNum, bool isValid) =
                    DateTime.getBitNumFromMaturity(blockTimeUTC0, maturity);
                require(isValid); // dev: remap bit section invalid maturity

                // Given the section that the `newBitNum` is located in, create a bit mask for the bit
                // and set it in the appropriate section of the bitmap.
                if (newBitNum <= Constants.WEEK_BIT_OFFSET) {
                    bytes32 bitMask = Constants.MSB >> (newBitNum - 1);
                    splitBitmap.dayBits = splitBitmap.dayBits | bitMask;
                } else if (newBitNum <= Constants.MONTH_BIT_OFFSET) {
                    bytes32 bitMask = Constants.MSB >> (newBitNum - Constants.WEEK_BIT_OFFSET - 1);
                    splitBitmap.weekBits = splitBitmap.weekBits | bitMask;
                } else if (newBitNum <= Constants.QUARTER_BIT_OFFSET) {
                    bytes32 bitMask = Constants.MSB >> (newBitNum - Constants.MONTH_BIT_OFFSET - 1);
                    splitBitmap.monthBits = splitBitmap.monthBits | bitMask;
                } else {
                    revert(); // dev: remap bit section error in bit shift
                }
            }

            // Shift the bits down as we remap. When we reach the end of `bitsToRemap` then the remaining
            // bits in this particular bitmap section will refer to the correct time positions relative to
            // `blockTimeUTC0` which will be the new `nextSettleTime` after the transaction is complete.
            bits = bits << 1;
        }

        return bits;
    }
}
