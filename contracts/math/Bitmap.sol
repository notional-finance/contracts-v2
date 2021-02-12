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
    bytes1 internal constant BIT1 = 0x80;
    bytes32 internal constant DAY_BITMASK     = 0xffffffffffffffffffffffc00000000000000000000000000000000000000000;
    bytes32 internal constant WEEK_BITMASK    = 0x00000000000000000000003ffffffffffe000000000000000000000000000000;
    bytes32 internal constant MONTH_BITMASK   = 0x0000000000000000000000000000000001ffffffffffffffe000000000000000;
    bytes32 internal constant QUARTER_BITMASK = 0x0000000000000000000000000000000000000000000000001fffffffffffffff;

    function splitfCashBitmap(
        bytes memory bitmap
    ) internal pure returns (SplitBitmap memory) {
        require(bitmap.length <= 32, "B: bitmap length");
        bytes32 bitmapDecoded = abi.decode(bitmap, (bytes32));
        
        return SplitBitmap(
            bitmapDecoded & DAY_BITMASK,
            (bitmapDecoded & WEEK_BITMASK) << CashGroup.WEEK_BIT_OFFSET,
            (bitmapDecoded & MONTH_BITMASK) << CashGroup.MONTH_BIT_OFFSET,
            (bitmapDecoded & QUARTER_BITMASK) << CashGroup.QUARTER_BIT_OFFSET
        );
    }

    function combinefCashBitmap(
        SplitBitmap memory splitBitmap
    ) internal pure returns (bytes memory) {
        bytes32 bitmapCombined = (
            splitBitmap.dayBits                                   |
            (splitBitmap.weekBits  >> CashGroup.WEEK_BIT_OFFSET)  |
            (splitBitmap.monthBits >> CashGroup.MONTH_BIT_OFFSET) |
            (splitBitmap.quarterBits >> CashGroup.QUARTER_BIT_OFFSET)
        );

        return abi.encode(bitmapCombined);
    }


    function setBit(bytes memory bitmap, uint index, bool setOn) internal pure returns (bytes memory) {
        require(index > 0, "B: zero index");
        uint byteOffset = (index - 1) / 8;
        bytes1 bitMask = BIT1 >> uint8((index - 1) % 8);

        if (bitmap.length < byteOffset + 1) {
            // If we're not setting the bit to on, there's no point in provisioning
            // a new bitmap here.
            if (!setOn) return bitmap;

            // Must provision a new bitmap
            bytes memory newBitmap = new bytes(byteOffset + 1);
            for (uint i; i < bitmap.length; i++) {
                newBitmap[i] = bitmap[i];
            }

            newBitmap[byteOffset] = bitMask;
            return newBitmap;
        }

        if (setOn) {
            bitmap[byteOffset] = bitmap[byteOffset] | bitMask;
        } else  {
            bitmap[byteOffset] = bitmap[byteOffset] & ~bitMask;
        }

        return bitmap;
    }

    // Checks if a particular bit is set in the bitmap
    function isBitSet(bytes memory bitmap, uint index) internal pure returns (bool) {
        require(index > 0, "B: zero index");

        uint byteOffset = (index - 1) / 8;
        if (bitmap.length < byteOffset + 1) return false;

        bytes1 bitMask = BIT1 >> uint8((index - 1) % 8);
        bool isActive = (bitmap[byteOffset] & bitMask) != 0x00;
        return isActive;
    }
    
    function totalBitsSet(bytes memory bitmap) internal pure returns (uint) {
        uint totalBits;
        for (uint i; i < bitmap.length; i++) {
            bytes1 bits = bitmap[i];
            if (bits == 0x00) continue;
            if (bits & 0x01 == 0x01) totalBits += 1;
            if (bits & 0x02 == 0x02) totalBits += 1;
            if (bits & 0x04 == 0x04) totalBits += 1;
            if (bits & 0x08 == 0x08) totalBits += 1;
            if (bits & 0x10 == 0x10) totalBits += 1;
            if (bits & 0x20 == 0x20) totalBits += 1;
            if (bits & 0x40 == 0x40) totalBits += 1;
            if (bits & 0x80 == 0x80) totalBits += 1;
        }

        return totalBits;
    }

}

contract MockBitmap {
    using Bitmap for bytes;

    function isBitSet(
        bytes memory bitmap,
        uint index
    ) public pure returns (bool) {
        return bitmap.isBitSet(index);
    }

    function setBit(
        bytes memory bitmap,
        uint index,
        bool setOn
    ) public pure returns (bytes memory) {
        return bitmap.setBit(index, setOn);
    }

    function totalBitsSet(
        bytes memory bitmap
    ) public pure returns (uint) {
        return bitmap.totalBitsSet();
    }

    function splitfCashBitmap(
        bytes memory bitmap
    ) public pure returns (SplitBitmap memory) {
        return bitmap.splitfCashBitmap();
    }

    function combinefCashBitmap(
        SplitBitmap memory splitBitmap
    ) public pure returns (bytes memory) {
        return Bitmap.combinefCashBitmap(splitBitmap);
    }
}