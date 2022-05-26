// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import "../math/FloatingPoint56.sol";
import "../math/Bitmap.sol";

contract MockFloatingPoint56 {
    function testPackingUnpacking(uint256 value)
        external
        pure
        returns (bytes32 packed, uint256 unpacked)
    {
        packed = bytes32(uint256(FloatingPoint56.packTo56Bits(value)));
        unpacked = FloatingPoint56.unpackFrom56Bits(uint256(packed));
    }

    function getMSB(uint256 x) external pure returns (uint256) {
        return Bitmap.getMSB(x);
    }
}
