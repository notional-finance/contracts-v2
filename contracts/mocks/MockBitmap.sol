// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/Bitmap.sol";

contract MockBitmap {
    using Bitmap for bytes32;

    function isBitSet(
        bytes32 bitmap,
        uint index
    ) public pure returns (bool) {
        return bitmap.isBitSet(index);
    }

    function setBit(
        bytes32 bitmap,
        uint index,
        bool setOn
    ) public pure returns (bytes32) {
        return bitmap.setBit(index, setOn);
    }

    function totalBitsSet(
        bytes32 bitmap
    ) public pure returns (uint) {
        return bitmap.totalBitsSet();
    }

    function splitfCashBitmap(
        bytes32 bitmap
    ) public pure returns (SplitBitmap memory) {
        return bitmap.splitfCashBitmap();
    }

    function combinefCashBitmap(
        SplitBitmap memory splitBitmap
    ) public pure returns (bytes32) {
        return Bitmap.combinefCashBitmap(splitBitmap);
    }
}
