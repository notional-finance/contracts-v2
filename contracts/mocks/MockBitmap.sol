// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

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

    function getMSB(uint256 x) external pure returns (uint256) {
        return Bitmap.getMSB(x);
    }

    function getNextBitNum(bytes32 x) external pure returns (uint256) {
        return Bitmap.getNextBitNum(x);
    }
}
