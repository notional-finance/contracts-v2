// SPDX-License-Identifier: BSD-4-Clause
/**
 * ABDK Math 64.64 Smart Contract Library.    Copyright © 2019 by ABDK Consulting.
 * Author: Mikhail Vladimirov <mikhail.vladimirov@gmail.com>
 */
pragma solidity ^0.7.0;

/**
 * Smart contract library of mathematical functions operating with signed
 * 64.64-bit fixed point numbers.    Signed 64.64-bit fixed point number is
 * basically a simple fraction whose numerator is signed 128-bit integer and
 * denominator is 2^64.    As long as denominator is always the same, there is no
 * need to store it, thus in Solidity signed 64.64-bit fixed point numbers are
 * represented by int128 type holding only the numerator.
 */
library ABDKMath64x64 {
    /* Minimum value signed 64.64-bit fixed point number may have. */
    int128 internal constant MIN_64x64 = -0x80000000000000000000000000000000;

    /* Maximum value signed 64.64-bit fixed point number may have. */
    int128 internal constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// Convert signed 256-bit integer number into signed 64.64-bit fixed point
    /// number.    Revert on overflow.
    /// @param x signed 256-bit integer number
    /// @return signed 64.64-bit fixed point number
    function fromInt(int256 x) internal pure returns (int128) {
        require(x >= -0x8000000000000000 && x <= 0x7FFFFFFFFFFFFFFF); // dev: abdk int256 overflow
        return int128(x << 64);
    }

    /// Convert signed 64.64 fixed point number into signed 64-bit integer number
    /// rounding down.
    /// @param x signed 64.64-bit fixed point number
    /// @return signed 64-bit integer number
    function toInt(int128 x) internal pure returns (int64) {
        return int64(x >> 64);
    }

    /// Convert unsigned 256-bit integer number into signed 64.64-bit fixed point
    /// number.    Revert on overflow.
    /// @param x unsigned 256-bit integer number
    /// @return signed 64.64-bit fixed point number
    function fromUInt(uint256 x) internal pure returns (int128) {
        require(x <= 0x7FFFFFFFFFFFFFFF); // dev: abdk uint overflow
        return int128(x << 64);
    }

    /// Convert signed 64.64 fixed point number into unsigned 64-bit integer
    /// number rounding down.    Revert on underflow.
    /// @param x signed 64.64-bit fixed point number
    /// @return unsigned 64-bit integer number
    function toUInt(int128 x) internal pure returns (uint64) {
        require(x >= 0); // dev: abdk uint overflow
        return uint64(x >> 64);
    }

    /// Calculate x * y rounding down.  Revert on overflow.
    /// @param x signed 64.64-bit fixed point number
    /// @param y signed 64.64-bit fixed point number
    /// @return signed 64.64-bit fixed point number
    function mul(int128 x, int128 y) internal pure returns (int128) {
        int256 result = (int256(x) * y) / 2**64;
        require(result >= MIN_64x64 && result <= MAX_64x64); // dev: abdk mul overflow
        return int128(result);
    }

    /// Calculate x / y rounding towards zero.  Revert on overflow or when y is
    /// zero.
    /// @param x signed 64.64-bit fixed point number
    /// @param y signed 64.64-bit fixed point number
    /// @return signed 64.64-bit fixed point number
    function div(int128 x, int128 y) internal pure returns (int128) {
        require(y != 0);
        int256 result = (int256(x) * 2**64) / y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    function add(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) + y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    function sub(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) - y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    int128 internal constant ONE = 2 ** 64;
    function ln(int128 x) internal pure returns (int128) {
        if(x <= 0) return 0;
        return (x- ONE) / 2;
        // return x;
    }

   
    function exp(int128 x) internal pure returns (int128) {
    //  if (x > mul(2,ONE)) return mul(20,x) - mul(40,ONE);
    //  if (x > mul(-2,ONE)) return div((x + mul(2,ONE)),mul(2,ONE));
     if (x > 2**65) return mul(20,x) - 2**66 * 10;
     if (x > -2**65) return ((x + 2**65) / (2**65));
     return 0;
        // return x;
    }
}