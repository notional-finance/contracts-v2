// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;

import "../global/Constants.sol";

library SafeInt256 {
    function mul(int256 a, int256 b) internal pure returns (int256 c) {
        c = a * b;
    }

    function div(int256 a, int256 b) internal pure returns (int256 c) {
        c = a / b;
    }

    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        z = x - y;
    }

    function add(int256 x, int256 y) internal pure returns (int256 z) {
        z = x + y;
    }

    function neg(int256 x) internal pure returns (int256 y) {
        y = -x;
    }

    function abs(int256 x) internal pure returns (int256) {
        if (x < 0) return -x;
        else return x;
    }

    function subNoNeg(int256 x, int256 y) internal pure returns (int256 z) {
        z = x - y;
        require(z >= 0); // dev: int256 sub to negative
    }

    /// @dev Calculates x * RATE_PRECISION / y while checking overflows
    function divInRatePrecision(int256 x, int256 y) internal pure returns (int256) {
        return div(mul(x, Constants.RATE_PRECISION), y);
    }

    /// @dev Calculates x * y / RATE_PRECISION while checking overflows
    function mulInRatePrecision(int256 x, int256 y) internal pure returns (int256) {
        return div(mul(x, y), Constants.RATE_PRECISION);
    }

    function toUint(int256 x) internal pure returns (uint256) {
        require(x >= 0);
        return uint256(x);
    }

    function toInt(uint256 x) internal pure returns (int256) {
        require (x <= uint256(type(int256).max));
        return int256(x);
    }

    function max(int256 x, int256 y) internal pure returns (int256) {
        return x > y ? x : y;
    }

    function min(int256 x, int256 y) internal pure returns (int256) {
        return x < y ? x : y;
    }
}