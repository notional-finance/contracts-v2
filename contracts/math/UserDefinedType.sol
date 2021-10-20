// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;

import "../global/Constants.sol";

/* User Defined Types */
type IU is int256;
type IA is int256;
type LT is int256;
type ER is int256; // exchange rate
type IR is uint256; // implied rate

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

    function abs(IU a) internal pure returns (IU) {
        return IU.unwrap(a) < 0 ? IU.wrap(-IU.unwrap(a)) : a;
    }

    function divInRatePrecision(IU x, ER y) internal pure returns (IU) {
        return IU.wrap(IU.unwrap(x) * Constants.RATE_PRECISION / ER.unwrap(y));
    }

    /// @dev Calculates x * y / RATE_PRECISION while checking overflows
    function mulInRatePrecision(IU x, ER y) internal pure returns (IU) {
        return IU.wrap(IU.unwrap(x) * ER.unwrap(y) / Constants.RATE_PRECISION);
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

    function isPosNotZero(LT a) internal pure returns (bool) {
        return LT.unwrap(a) > 0;
    }

    function toStorage(LT a) internal pure returns (uint80) {
        require(0 <= LT.unwrap(a) && LT.unwrap(a) <= int256(uint256(type(uint80).max))); // dev: storage overflow
        return uint80(uint256(LT.unwrap(a)));
    }

    /**** Exchange Rates and Implied Rates */
    function isZero(IR a) internal pure returns (bool) {
        return IR.unwrap(a) == 0;
    }

    function isPosNotZero(IR a) internal pure returns (bool) {
        return IR.unwrap(a) > 0;
    }

    function add(IR a, IR b) internal pure returns (IR) {
        return IR.wrap(IR.unwrap(a) + IR.unwrap(b));
    }

    function sub(IR a, IR b) internal pure returns (IR) {
        return IR.wrap(IR.unwrap(a) - IR.unwrap(b));
    }

    function subFloorZero(IR a, IR b) internal pure returns (IR) {
        if (IR.unwrap(a) >= IR.unwrap(b)) return IR.wrap(0);
        else return IR.wrap(IR.unwrap(a) - IR.unwrap(b));
    }

    function gt(IR a, IR b) internal pure returns (bool) {
        return IR.unwrap(a) > IR.unwrap(b);
    }

    function gte(IR a, IR b) internal pure returns (bool) {
        return IR.unwrap(a) >= IR.unwrap(b);
    }

    function lt(IR a, IR b) internal pure returns (bool) {
        return IR.unwrap(a) < IR.unwrap(b);
    }

    function lte(IR a, IR b) internal pure returns (bool) {
        return IR.unwrap(a) <= IR.unwrap(b);
    }

    function toStorage(IR a) internal pure returns (uint32) {
        require(IR.unwrap(a) <= uint256(type(uint32).max)); // dev: storage overflow
        return uint32(IR.unwrap(a));
    }

    function isInvalidExchangeRate(ER a) internal pure returns (bool) {
        return ER.unwrap(a) < Constants.RATE_PRECISION;
    }

    function isValidDiscountFactor(ER a) internal pure returns (bool) {
        return ER.unwrap(a) <= Constants.RATE_PRECISION;
    }

    function sub(ER a, ER b) internal pure returns (ER) {
        return ER.wrap(ER.unwrap(a) - ER.unwrap(b));
    }
}