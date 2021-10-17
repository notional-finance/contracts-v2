// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;

import "../global/Constants.sol";

/* User Defined Types */
type IU is int256;
type IA is int256;
type LT is int256;

library UserDefinedType {
    function scale(IA a, int256 numerator, int256 divisor) internal pure returns (IA) {
        return IA.wrap((IA.unwrap(a) * numerator) / divisor);
    }

    function add(IA a, IA b) internal pure returns (IA) {
        return IA.wrap(IA.unwrap(a) + IA.unwrap(b));
    }

    function sub(IA a, IA b) internal pure returns (IA) {
        return IA.wrap(IA.unwrap(a) - IA.unwrap(b));
    }

    function subNoNeg(IA a, IA b) internal pure returns (IA) {
        int256 c = IA.unwrap(a) - IA.unwrap(b);
        require(c >= 0);
        return IA.wrap(c);
    }

    function neg(IA a) internal pure returns (IA) {
        return IA.wrap(-IA.unwrap(a));
    }

    function gt(IA a, IA b) internal pure returns (bool) {
        return IA.unwrap(a) > IA.unwrap(b);
    }

    function gte(IA a, IA b) internal pure returns (bool) {
        return IA.unwrap(a) >= IA.unwrap(b);
    }

    function lt(IA a, IA b) internal pure returns (bool) {
        return IA.unwrap(a) < IA.unwrap(b);
    }

    function lte(IA a, IA b) internal pure returns (bool) {
        return IA.unwrap(a) <= IA.unwrap(b);
    }

    function eq(IA a, IA b) internal pure returns (bool) {
        return IA.unwrap(a) == IA.unwrap(b);
    }

    function neq(IA a, IA b) internal pure returns (bool) {
        return IA.unwrap(a) != IA.unwrap(b);
    }

    function isNotZero(IA a) internal pure returns (bool) {
        return IA.unwrap(a) != 0;
    }

    function isZero(IA a) internal pure returns (bool) {
        return IA.unwrap(a) == 0;
    }

    function isNegOrZero(IA a) internal pure returns (bool) {
        return IA.unwrap(a) <= 0;
    }

    function isNegNotZero(IA a) internal pure returns (bool) {
        return IA.unwrap(a) < 0;
    }

    function isPosOrZero(IA a) internal pure returns (bool) {
        return IA.unwrap(a) >= 0;
    }

    function isPosNotZero(IA a) internal pure returns (bool) {
        return IA.unwrap(a) > 0;
    }

    function toMarketStorage(IA a) internal pure returns (uint80) {
        require(0 <= IA.unwrap(a) && IA.unwrap(a) <= int256(uint256(type(uint80).max))); // dev: storage overflow
        return uint80(uint256(IA.unwrap(a)));
    }

    function toBalanceStorage(IA a) internal pure returns (int88) {
        require(type(int88).min <= IA.unwrap(a) && IA.unwrap(a) <= type(int88).max); // dev: stored cash balance overflow
        return int88(IA.unwrap(a));
    }

    /**** INTERNAL UNDERLYING ****************/

    function scale(IU a, int256 numerator, int256 divisor) internal pure returns (IU) {
        return IU.wrap((IU.unwrap(a) * numerator) / divisor);
    }

    function add(IU a, IU b) internal pure returns (IU) {
        return IU.wrap(IU.unwrap(a) + IU.unwrap(b));
    }

    function sub(IU a, IU b) internal pure returns (IU) {
        return IU.wrap(IU.unwrap(a) - IU.unwrap(b));
    }

    function subNoNeg(IU a, IU b) internal pure returns (IU) {
        int256 c = IU.unwrap(a) - IU.unwrap(b);
        require(c >= 0);
        return IU.wrap(c);
    }

    function neg(IU a) internal pure returns (IU) {
        return IU.wrap(-IU.unwrap(a));
    }

    function gt(IU a, IU b) internal pure returns (bool) {
        return IU.unwrap(a) > IU.unwrap(b);
    }

    function gte(IU a, IU b) internal pure returns (bool) {
        return IU.unwrap(a) >= IU.unwrap(b);
    }

    function lt(IU a, IU b) internal pure returns (bool) {
        return IU.unwrap(a) < IU.unwrap(b);
    }

    function lte(IU a, IU b) internal pure returns (bool) {
        return IU.unwrap(a) <= IU.unwrap(b);
    }

    function eq(IU a, IU b) internal pure returns (bool) {
        return IU.unwrap(a) == IU.unwrap(b);
    }

    function isNotZero(IU a) internal pure returns (bool) {
        return IU.unwrap(a) != 0;
    }

    function isZero(IU a) internal pure returns (bool) {
        return IU.unwrap(a) == 0;
    }

    function isNegOrZero(IU a) internal pure returns (bool) {
        return IU.unwrap(a) <= 0;
    }

    function isNegNotZero(IU a) internal pure returns (bool) {
        return IU.unwrap(a) < 0;
    }

    function isPosOrZero(IU a) internal pure returns (bool) {
        return IU.unwrap(a) >= 0;
    }

    function isPosNotZero(IU a) internal pure returns (bool) {
        return IU.unwrap(a) > 0;
    }

    function divInRatePrecision(IU x, int256 y) internal pure returns (IU) {
        return IU.wrap(IU.unwrap(x) * Constants.RATE_PRECISION / y);
    }

    /// @dev Calculates x * y / RATE_PRECISION while checking overflows
    function mulInRatePrecision(IU x, int256 y) internal pure returns (IU) {
        return IU.wrap(IU.unwrap(x) * y / Constants.RATE_PRECISION);
    }

    function toStorage(IU a) internal pure returns (uint80) {
        require(0 <= IU.unwrap(a) && IU.unwrap(a) <= int256(uint256(type(uint80).max))); // dev: storage overflow
        return uint80(uint256(IU.unwrap(a)));
    }

    /**** Liquidity Token ****************/

    function scale(LT a, int256 numerator, int256 divisor) internal pure returns (LT) {
        return LT.wrap((LT.unwrap(a) * numerator) / divisor);
    }

    function add(LT a, LT b) internal pure returns (LT) {
        return LT.wrap(LT.unwrap(a) + LT.unwrap(b));
    }

    function sub(LT a, LT b) internal pure returns (LT) {
        return LT.wrap(LT.unwrap(a) - LT.unwrap(b));
    }

    function subNoNeg(LT a, LT b) internal pure returns (LT) {
        int256 c = LT.unwrap(a) - LT.unwrap(b);
        require(c >= 0);
        return LT.wrap(c);
    }

    function neg(LT a) internal pure returns (LT) {
        return LT.wrap(-LT.unwrap(a));
    }

    function isZero(LT a) internal pure returns (bool) {
        return LT.unwrap(a) == 0;
    }

    function gt(LT a, LT b) internal pure returns (bool) {
        return LT.unwrap(a) > LT.unwrap(b);
    }

    function gte(LT a, LT b) internal pure returns (bool) {
        return LT.unwrap(a) >= LT.unwrap(b);
    }

    function lt(LT a, LT b) internal pure returns (bool) {
        return LT.unwrap(a) < LT.unwrap(b);
    }

    function lte(LT a, LT b) internal pure returns (bool) {
        return LT.unwrap(a) <= LT.unwrap(b);
    }

    function eq(LT a, LT b) internal pure returns (bool) {
        return LT.unwrap(a) == LT.unwrap(b);
    }

    function toStorage(LT a) internal pure returns (uint80) {
        require(0 <= LT.unwrap(a) && LT.unwrap(a) <= int256(uint256(type(uint80).max))); // dev: storage overflow
        return uint80(uint256(LT.unwrap(a)));
    }
}