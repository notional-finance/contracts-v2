// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/CashGroup.sol";

struct SplitBitmap {
    bytes32 dayBits;
    bytes32 weekBits;
    bytes32 monthBits;
    bytes32 quarterBits;
}

/**
 * @notice Higher level library for dealing with bitmaps in the system. Bitmaps are
 * big-endian and 1-indexed.
 */
library Bitmap {
    bytes32 internal constant MSB = 0x8000000000000000000000000000000000000000000000000000000000000000;
    bytes32 internal constant DAY_BITMASK     = 0xffffffffffffffffffffffc00000000000000000000000000000000000000000;
    bytes32 internal constant WEEK_BITMASK    = 0x00000000000000000000003ffffffffffe000000000000000000000000000000;
    bytes32 internal constant MONTH_BITMASK   = 0x0000000000000000000000000000000001ffffffffffffffe000000000000000;
    bytes32 internal constant QUARTER_BITMASK = 0x0000000000000000000000000000000000000000000000001fffffffffffffff; 

    function splitfCashBitmap(
        bytes32 bitmap
    ) internal pure returns (SplitBitmap memory) {
        return SplitBitmap(
            bitmap & DAY_BITMASK,
            (bitmap & WEEK_BITMASK) << CashGroup.WEEK_BIT_OFFSET,
            (bitmap & MONTH_BITMASK) << CashGroup.MONTH_BIT_OFFSET,
            (bitmap & QUARTER_BITMASK) << CashGroup.QUARTER_BIT_OFFSET
        );
    }

    function combinefCashBitmap(
        SplitBitmap memory splitBitmap
    ) internal pure returns (bytes32) {
        bytes32 bitmapCombined = (
            splitBitmap.dayBits                                   |
            (splitBitmap.weekBits   >> CashGroup.WEEK_BIT_OFFSET)  |
            (splitBitmap.monthBits  >> CashGroup.MONTH_BIT_OFFSET) |
            (splitBitmap.quarterBits >> CashGroup.QUARTER_BIT_OFFSET)
        );

        return bitmapCombined;
    }

    function setBit(bytes32 bitmap, uint index, bool setOn) internal pure returns (bytes32) {
        require(index >= 1 && index <= 256); // dev: set bit index bounds

        if (setOn) {
            return bitmap | (MSB >> (index - 1));
        } else {
            return bitmap & ~(MSB >> (index - 1));
        }
    }

    function isBitSet(bytes32 bitmap, uint index) internal pure returns (bool) {
        require(index >= 1 && index <= 256); // dev: set bit index bounds
        return (bitmap << (index - 1) & MSB) == MSB;
    }
    
    function totalBitsSet(bytes32 bitmap) internal pure returns (uint) {
        uint totalBits;

        bytes32 copy = bitmap;

        while (copy != 0) {
            if (copy & MSB == MSB) totalBits += 1;
            copy = copy << 1;
        }

        return totalBits;
    }
}
