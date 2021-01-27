// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;

/**
 * @notice Higher level library for dealing with bitmaps in the system. Bitmaps are
 * big-endian and 1-indexed.
 */
library Bitmap {
    bytes1 internal constant BIT1 = 0x80;

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
}