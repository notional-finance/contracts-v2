// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/Bitmap.sol";

contract MockBitmap {
    using Bitmap for bytes32;

    function isBitSet(bytes32 bitmap, uint256 index) public pure returns (bool) {
        return bitmap.isBitSet(index);
    }

    function setBit(
        bytes32 bitmap,
        uint256 index,
        bool setOn
    ) public pure returns (bytes32) {
        return bitmap.setBit(index, setOn);
    }

    function totalBitsSet(bytes32 bitmap) public pure returns (uint256) {
        return bitmap.totalBitsSet();
    }

    function splitAssetBitmap(bytes32 bitmap) public pure returns (SplitBitmap memory) {
        return bitmap.splitAssetBitmap();
    }

    function combineAssetBitmap(SplitBitmap memory splitBitmap) public pure returns (bytes32) {
        return Bitmap.combineAssetBitmap(splitBitmap);
    }
}
