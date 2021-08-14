// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../markets/AssetRate.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";

/**
 * Settles a bitmap portfolio by checking for all matured fCash assets and turning them into cash
 * at the prevailing settlement rate. It will also update the asset bitmap to ensure that it continues
 * to correctly reference all actual maturities. fCash asset notional values are stored in *absolute* 
 * time terms and bitmap bits are *relative* time terms based on the bitNumber and the stored oldSettleTime.
 * Remapping bits requires converting the old relative bit numbers to new relative bit numbers based on
 * newSettleTime and the absolute times (maturities) that the previous bitmap references.
 */
library SettleBitmapAssets {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Bitmap for bytes32;

    /// @notice Given a bitmap for a cash group and timestamps, will settle all assets
    /// that have matured and remap the bitmap to correspond to the current time.
    function settleBitmappedCashGroup(
        address account,
        uint256 currencyId,
        uint256 oldSettleTime,
        uint256 blockTime
    ) internal returns (bytes32 bitmap, int256 totalAssetCash, uint256 newSettleTime) {
        bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);

        // This newSettleTime will be set to the new `oldSettleTime`. The bits between 1 and
        // `lastSettleBit` (inclusive) will be shifted out of the bitmap and settled. The reason
        // that lastSettleBit is inclusive is that it refers to newSettleTime which always less
        // than the current block time.
        newSettleTime = DateTime.getTimeUTC0(blockTime);
        require(newSettleTime >= oldSettleTime); // dev: new settle time before previous

        // Do not need to worry about validity, if newSettleTime is not on an exact bit we will settle up until
        // the closest maturity that is less than newSettleTime.
        (uint256 lastSettleBit, /* isValid */) = DateTime.getBitNumFromMaturity(oldSettleTime, newSettleTime);
        if (lastSettleBit == 0) return (bitmap, totalAssetCash, newSettleTime);

        // Returns the next bit that is set in the bitmap using a binary search for the MSB.
        uint256 nextBitNum = bitmap.getNextBitNum();
        while (nextBitNum != 0 && nextBitNum <= lastSettleBit) {
            uint256 maturity = DateTime.getMaturityFromBitNum(oldSettleTime, nextBitNum);
            totalAssetCash = totalAssetCash.add(
                _settlefCashAsset(account, currencyId, maturity, blockTime)
            );
            // Turn the bit off now that it is settled
            bitmap = bitmap.setBit(nextBitNum, false);

            // Continue the loop
            nextBitNum = bitmap.getNextBitNum();
        }

        // If there are no more bits in the bitmap then we can skip remapping
        if (nextBitNum == 0) return (bitmap, totalAssetCash, newSettleTime);

        ///////// REMAPPING ////////////
        // Split the bitmap into its four time sections so that we can more easily manipulate them.
        SplitBitmap memory splitBitmap = bitmap.splitAssetBitmap();
        // Day bits don't need remapping to lower time sections, just shift settled assets away.
        splitBitmap.dayBits <<= lastSettleBit;

        // Remapping required for weeks, months and quarters.
        splitBitmap.weekBits = _remapBitSection(
            splitBitmap, lastSettleBit, oldSettleTime, newSettleTime,
            splitBitmap.weekBits, Constants.WEEK_BIT_OFFSET, Constants.WEEK
        );

        splitBitmap.monthBits = _remapBitSection(
            splitBitmap, lastSettleBit, oldSettleTime, newSettleTime,
            splitBitmap.monthBits, Constants.MONTH_BIT_OFFSET, Constants.MONTH
        );

        splitBitmap.quarterBits = _remapBitSection(
            splitBitmap, lastSettleBit, oldSettleTime, newSettleTime,
            splitBitmap.quarterBits, Constants.QUARTER_BIT_OFFSET, Constants.QUARTER
        );

        // Recombine the bitmap sections into a single bitmap
        bitmap = Bitmap.combineAssetBitmap(splitBitmap);
        return (bitmap, totalAssetCash, newSettleTime);
    }

    /// @dev Remaps a week, month or quarter bit section. First calculates how many bits need to be
    /// remapped from the current section into lower sections and then does all the required shifting.
    /// @param splitBitmap contains all bitmap sections
    /// @param lastSettleBit is the highest bit number we've settled to
    /// @param oldSettleTime previous settle time that the bit section references at the beginning of the method
    /// @param newSettleTime new settle time that the bit section will reference at the end of the method
    /// @param bitSection section of split bitmap that will be remapped
    /// @param sectionBitOffset the offset from the initial bit number of this particular bit section
    /// @param timeChunkLength the length of time between bits in this bit section
    function _remapBitSection(
        SplitBitmap memory splitBitmap,
        uint256 lastSettleBit,
        uint256 oldSettleTime,
        uint256 newSettleTime,
        bytes32 bitSection,
        uint256 sectionBitOffset,
        uint256 timeChunkLength
    ) private returns (bytes32) {
        // Nothing to remap if all zeros
        if (bitSection == 0x00) return bitSection;

        (
            uint256 settledBits,
            uint256 bitsToDaySection,
            uint256 bitsToWeekSection,
            uint256 bitsToMonthSection
        ) = _calculateBitsToRemap(
            oldSettleTime,
            newSettleTime,
            lastSettleBit,
            sectionBitOffset,
            timeChunkLength
        );

        // Settled bits are shifted off of the bit section, no remapping required.
        bitSection <<= settledBits;

        if (bitsToDaySection > 0) {
            // Remap offset is the first bit in the dayBits that we will start remapping from.
            uint256 remapOffset = _getRemapOffset(oldSettleTime, newSettleTime, sectionBitOffset, settledBits);
            (bitSection, splitBitmap.dayBits) = _remap(
                bitSection,
                splitBitmap.dayBits,
                remapOffset,
                timeChunkLength / Constants.DAY,
                bitsToDaySection
            );

            // Add to the count of settled bitSection for the next sections to properly calculate
            // the `remapOffset`
            settledBits += bitsToDaySection;
        }

        if (bitsToWeekSection > 0) {
            uint256 remapOffset = _getRemapOffset(oldSettleTime, newSettleTime, sectionBitOffset, settledBits);
            // Remap offset is calculated based on the entire bitmap, however, the split bitmap is shifted
            // to the left for each bit section so we calculate the relative offset for the week section.
            remapOffset = remapOffset - Constants.WEEK_BIT_OFFSET;

            (bitSection, splitBitmap.weekBits) = _remap(
                bitSection,
                splitBitmap.weekBits,
                remapOffset,
                timeChunkLength / Constants.WEEK,
                bitsToWeekSection
            );

            settledBits += bitsToWeekSection;
        }

        if (bitsToMonthSection > 0) {
            uint256 remapOffset = _getRemapOffset(oldSettleTime, newSettleTime, sectionBitOffset, settledBits);
            remapOffset = remapOffset - Constants.MONTH_BIT_OFFSET;

            (bitSection, splitBitmap.monthBits) = _remap(
                bitSection,
                splitBitmap.monthBits,
                remapOffset,
                timeChunkLength / Constants.MONTH,
                bitsToMonthSection
            );
        }

        return bitSection;
    }

    function _calculateBitsToRemap(
        uint256 oldSettleTime,
        uint256 newSettleTime,
        uint256 lastSettleBit,
        uint256 sectionBitOffset,
        uint256 timeChunkLength
    ) private pure returns (uint256, uint256, uint256, uint256) {
        // If lastSettleBit is higher than the section bit offset, the difference is the
        // number of bits in this section that have been settled (i.e. are now in the past)
        uint256 settledBits = subFloorZero(lastSettleBit, sectionBitOffset);
        uint256 bitsToRemap = _getBitsToRemap(
            oldSettleTime,
            newSettleTime,
            lastSettleBit,
            sectionBitOffset,
            timeChunkLength,
            settledBits
        );

        if (bitsToRemap == 0) return (settledBits, 0, 0, 0);
        // All week bits will be remapped down to day section
        if (sectionBitOffset == Constants.WEEK_BIT_OFFSET) return (settledBits, bitsToRemap, 0, 0);

        uint256 dayBits = _getBitsToRemapSection(
            oldSettleTime,
            newSettleTime,
            sectionBitOffset,
            settledBits,
            Constants.WEEK_BIT_OFFSET
        );

        if (sectionBitOffset == Constants.MONTH_BIT_OFFSET) {
            // check overflow
            return (settledBits, dayBits, bitsToRemap - dayBits, 0);
        }

        uint256 weekBits = _getBitsToRemapSection(
            oldSettleTime,
            newSettleTime,
            sectionBitOffset,
            settledBits + dayBits,
            Constants.MONTH_BIT_OFFSET
        );
        return (
            settledBits,
            dayBits,
            weekBits,
            bitsToRemap - dayBits - weekBits // check underflow
        );
    }

    function _getBitsToRemap(
        uint256 oldSettleTime,
        uint256 newSettleTime,
        uint256 lastSettleBit,
        uint256 sectionBitOffset,
        uint256 timeChunkLength,
        uint256 settledBits
    ) private pure returns (uint256) {
        // The part of a bit section that requires remapping is the part of the bit section that is no longer
        // referenced by a bit section. This can be calculated by the difference in the absolute time that the
        // first (non settled) bit the bit section references. For example, the first week bit may reference:
        // Old Bit 91 Reference @ Jan 1 2020
        // New Bit 91 Reference @ Feb 1 2020
        // The difference in these reference times is 30 days. That means the first 5 bits in the week bit
        // section are no longer referenced in that section.

        // This is the first valid (non settled) bit in the new bit section. Max is required here because
        // a bit reference less than `lastSettleBit` will be in the past.
        uint256 bitReference = max(lastSettleBit, sectionBitOffset) + 1;
        uint256 newReference = DateTime.getMaturityFromBitNum(newSettleTime, bitReference);
        uint256 oldReference = DateTime.getMaturityFromBitNum(oldSettleTime, bitReference);

        // If there are settled bits, bitReference is inclusive of them. Subtract them from the bits
        // that actually need to be remapped.
        return (newReference - oldReference) / timeChunkLength - settledBits;
    }

    function _getBitsToRemapSection(
        uint256 oldSettleTime,
        uint256 newSettleTime,
        uint256 chunkOffset,
        uint256 settledBits,
        uint256 remapSectionOffset
    ) internal pure returns (uint256) {
        // Here is a diagram of what is calculated in this function:
        //
        // new:                   (settled) | day          | week          | month     
        //                                                 ^ maxMaturity
        // old: | day | week | month         xxxxxxxxxxxxxx        |
        //      chunk offset ^ settled bits ^              ^ oldBitReference
        //                                   (bits to remap)

        // This is the maximum cutoff maturity for bits in the day bit section.
        uint256 maxMaturity = DateTime.getMaturityFromBitNum(newSettleTime, remapSectionOffset);

        // Now get the bit in the old bitmap that refers to this new max day bit. It is irrelevant if the
        // bit is valid, this will return the nearest bit less than the supplied maturity.
        (uint256 oldBitReference, /* bool isValid */) = DateTime.getBitNumFromMaturity(oldSettleTime, maxMaturity);

        // Now calculate the number of bits that need to be shifted down to the section. This will be
        // any bits above oldBitReference that remain in the chunk and have not yet been settled.
        return subFloorZero(oldBitReference, chunkOffset + settledBits);
    }

    function _getRemapOffset(
        uint256 oldSettleTime,
        uint256 newSettleTime,
        uint256 sectionBitOffset,
        uint256 totalBitsShifted
    ) internal pure returns (uint256) {
        // This is the maturity (absolute terms) of the bit number just after the point where we've
        // settled or remapped up to.
        uint256 m = DateTime.getMaturityFromBitNum(oldSettleTime, sectionBitOffset + totalBitsShifted + 1);
        // Get the bit number of this maturity (absolute terms) in the new relative terms (newSettleTime)
        // that the bitmap will be shifted to.
        (uint256 remapOffset, bool isValid) = DateTime.getBitNumFromMaturity(newSettleTime, m);
        // The toOffset must be valid, this is ensured because all time chunks are divisible by
        // each other so that any valid maturity can be remapped to a bit number regardless of "settle time"
        // the bitmap is relative to.
        require(isValid); // dev: get offset invalid

        return remapOffset;
    }

    /// @dev Remaps `count` bits from the `fromBits` to the `toBits` 32 byte words. Starts
    /// from the MSB in `fromBits` and maps from the `toOffset` in the `toBits`.
    /// The `toOffset` will be incremented in `stepSize` on each bit that is shifted.
    function _remap (
        bytes32 fromBits,
        bytes32 toBits,
        uint256 toOffset,
        uint256 stepSize,
        uint256 count
    ) internal pure returns (bytes32, bytes32) {
        require(toOffset > 0); // dev: toOffset is not 1-indexed

        while (count --> 0) {
            // `fromOffset` is the current bit we want to remap. Clear all the other bits 
            // using `& Constants.MSB`. Shift to the `toOffset` and OR it into place.
            // `toOffset` is one indexed but shifts are zero indexed.
            toBits |= (fromBits & Constants.MSB) >> (toOffset - 1);
            // Shift from bits down after remapping so that the next remapped bit is at MSB
            fromBits <<= 1;
            toOffset += stepSize;
        }

        return (fromBits, toBits);
    }

    /// @dev Ensures that we don't get a negative shift value.
    function subFloorZero(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    function max(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x : y;
    }

    /// @dev Stateful settlement function to settle a bitmapped asset. Deletes the
    /// asset from storage after calculating it.
    function _settlefCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) private returns (int256 assetCash) {
        // Storage Read
        bytes32 ifCashSlot = BitmapAssetsHandler.getifCashSlot(account, currencyId, maturity);
        int256 ifCash;
        assembly {
            ifCash := sload(ifCashSlot)
        }

        // Gets the current settlement rate or will store a new settlement rate if it does not
        // yet exist.
        AssetRateParameters memory rate =
            AssetRate.buildSettlementRateStateful(currencyId, maturity, blockTime);
        assetCash = rate.convertFromUnderlying(ifCash);
        // Delete ifCash value
        assembly {
            sstore(ifCashSlot, 0)
        }

        return assetCash;
    }
}
