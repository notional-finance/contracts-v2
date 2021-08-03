// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;

/**
 * Packs an uint value into a "floating point" storage slot. Used for storing
 * lastClaimSupply integral values in balance storage. For these values, we don't need
 * to maintain exact precision but we don't want to be limited by storage size overflows.
 *
 * A floating point value is defined by the 48 most significant bits and an 8 bit number
 * of bit shifts required to restore its precision. The unpacked value will always be less
 * than the packed value with a maximum absolute loss of precision of (2 ** bitShift) - 1.
 */
library FloatingPoint56 {

    function packTo56Bits(uint256 value) internal pure returns (bytes32) {
        uint256 bitShift;
        // If the value is over the uint48 max value then we will shift it down
        // given the index of the most significant bit. We store this bit shift 
        // in the least significant byte of the 56 bit slot available.
        if (value > type(uint48).max) bitShift = getMSB(value);

        uint256 shiftedValue = value >> bitShift;
        return bytes32((shiftedValue << 8) | bitShift);
    }

    function unpackFrom56Bits(uint256 value) internal pure returns (uint256) {
        // The least significant 8 bits will be the amount to bit shift
        uint256 bitShift = uint256(uint8(uint256(value)));
        return uint256((value >> 8) << bitShift);
    }

    // Does a binary search over x to get the position of the most significant bit
    function getMSB(uint256 x) internal pure returns (uint256 msb) {
        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            msb += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            msb += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            msb += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            msb += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            msb += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            msb += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            msb += 2;
        }
        if (x >= 0x2) msb += 1; // No need to shift xc anymore
    }
}
