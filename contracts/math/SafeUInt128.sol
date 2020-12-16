// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;


library SafeUInt128 {
    function add(uint128 a, uint128 b) internal pure returns (uint128) {
        uint128 c = a + b;
        require(c >= a, "uint128: add overflow");
        return c;
    }

    /**
     * @notice x-y. You can use add(x,-y) instead.
     * @dev Tests covered by add(x,y)
     */
    function sub(uint128 a, uint128 b) internal pure returns (uint128) {
        uint128 c = a - b;
        require(c <= a, "uint128: sub underflow");
        return c;
    }

    function mul(uint128 x, uint128 y) internal pure returns (uint128) {
        if (x == 0) {
            return 0;
        }

        uint128 z = x * y;
        require(z / x == y, "uint128: mul overflow");

        return z;
    }

    function div(uint128 x, uint128 y) internal pure returns (uint128) {
        require(y > 0, "uint128: div by zero");
        return x / y;
    }
}
