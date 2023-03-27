// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;

import "../math/FloatingPoint.sol";
import "../math/Bitmap.sol";

contract MockFloatingPoint {
    function testPackingUnpacking56(uint256 value)
        external
        pure
        returns (bytes32 packed, uint256 unpacked)
    {
        packed = bytes32(uint256(FloatingPoint.packTo56Bits(value)));
        unpacked = FloatingPoint.unpackFromBits(uint256(packed));
    }

    function testPackingUnpacking32(uint256 value)
        external
        pure
        returns (bytes32 packed, uint256 unpacked)
    {
        packed = bytes32(uint256(FloatingPoint.packTo32Bits(value)));
        unpacked = FloatingPoint.unpackFromBits(uint256(packed));
    }

    function getMSB(uint256 x) external pure returns (uint256) {
        return Bitmap.getMSB(x);
    }
}
