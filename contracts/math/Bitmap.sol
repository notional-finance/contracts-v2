// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../global/Types.sol";
import "../global/Constants.sol";

/// @notice Helper methods for bitmaps, they are big-endian and 1-indexed.
library Bitmap {
    bytes32 private constant DAY_BITMASK =
        0xffffffffffffffffffffffc00000000000000000000000000000000000000000;
    bytes32 private constant WEEK_BITMASK =
        0x00000000000000000000003ffffffffffe000000000000000000000000000000;
    bytes32 private constant MONTH_BITMASK =
        0x0000000000000000000000000000000001ffffffffffffffe000000000000000;
    bytes32 private constant QUARTER_BITMASK =
        0x0000000000000000000000000000000000000000000000001fffffffffffffff;

    /// @notice Splits an asset bitmap into its constituent time chunks
    function splitAssetBitmap(bytes32 bitmap) internal pure returns (SplitBitmap memory) {
        return
            SplitBitmap(
                bitmap & DAY_BITMASK,
                (bitmap & WEEK_BITMASK) << Constants.WEEK_BIT_OFFSET,
                (bitmap & MONTH_BITMASK) << Constants.MONTH_BIT_OFFSET,
                (bitmap & QUARTER_BITMASK) << Constants.QUARTER_BIT_OFFSET
            );
    }

    /// @notice Recombine a split asset bitmap
    function combineAssetBitmap(SplitBitmap memory splitBitmap) internal pure returns (bytes32) {
        bytes32 bitmapCombined =
            (splitBitmap.dayBits |
                (splitBitmap.weekBits >> Constants.WEEK_BIT_OFFSET) |
                (splitBitmap.monthBits >> Constants.MONTH_BIT_OFFSET) |
                (splitBitmap.quarterBits >> Constants.QUARTER_BIT_OFFSET));

        return bitmapCombined;
    }

    /// @notice Set a bit on or off in a bitmap, index is 1-indexed
    function setBit(
        bytes32 bitmap,
        uint256 index,
        bool setOn
    ) internal pure returns (bytes32) {
        require(index >= 1 && index <= 256); // dev: set bit index bounds

        if (setOn) {
            return bitmap | (Constants.MSB >> (index - 1));
        } else {
            return bitmap & ~(Constants.MSB >> (index - 1));
        }
    }

    /// @notice Check if a bit is set
    function isBitSet(bytes32 bitmap, uint256 index) internal pure returns (bool) {
        require(index >= 1 && index <= 256); // dev: set bit index bounds
        return ((bitmap << (index - 1)) & Constants.MSB) == Constants.MSB;
    }

    /// @notice Count the total bits set
    function totalBitsSet(bytes32 bitmap) internal pure returns (uint256) {
        uint256 totalBits;

        bytes32 copy = bitmap;

        while (copy != 0) {
            if (copy & Constants.MSB == Constants.MSB) totalBits += 1;
            copy = copy << 1;
        }

        return totalBits;
    }
}
