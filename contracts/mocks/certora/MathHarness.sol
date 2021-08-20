// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/balances/Incentives.sol";
import "../../internal/nTokenHandler.sol";
import "../../internal/markets/DateTime.sol";
import "../../internal/markets/AssetRate.sol";
import "../../internal/valuation/ExchangeRate.sol";
import "../../global/Types.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";
import "../../math/FloatingPoint56.sol";

contract MathHarness {
    /////// Date Time Math /////////
    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        public
        pure
        returns (uint256, bool)
    {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        public
        pure
        returns (uint256)
    {
        return DateTime.getMaturityFromBitNum(blockTime, bitNum);
    }

    function isValidMaturity(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) public pure returns (bool) {
        return DateTime.isValidMaturity(maxMarketIndex, maturity, blockTime);
    }

    function getMarketIndex(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) public pure returns (uint256, bool) {
        return DateTime.getMarketIndex(maxMarketIndex, maturity, blockTime);
    }

    function isValidMarketMaturity(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) public pure returns (bool) {
        return DateTime.isValidMarketMaturity(maxMarketIndex, maturity, blockTime);
    }

    /////// SafeInt Math /////////
    function mul(int256 a, int256 b) public pure returns (int256) {
        return SafeInt256.mul(a, b);
    }

    function div(int256 a, int256 b) public pure returns (int256) {
        return SafeInt256.div(a, b);
    }

    function sub(int256 x, int256 y) public pure returns (int256 z) {
        return SafeInt256.sub(x, y);
    }

    function add(int256 x, int256 y) public pure returns (int256 z) {
        return SafeInt256.add(x, y);
    }

    function neg(int256 x) public pure returns (int256) {
        return SafeInt256.neg(x);
    }

    function abs(int256 x) public pure returns (int256) {
        return SafeInt256.abs(x);
    }

    function subNoNeg(int256 x, int256 y) public pure returns (int256) {
        return SafeInt256.subNoNeg(x, y);
    }

    function divInRatePrecision(int256 x, int256 y) public pure returns (int256) {
        return SafeInt256.divInRatePrecision(x, y);
    }

    function mulInRatePrecision(int256 x, int256 y) public pure returns (int256) {
        return SafeInt256.mulInRatePrecision(x, y);
    }

    /////// Bitmap /////////
    function setBit(
        bytes32 bitmap,
        uint256 index,
        bool setOn
    ) public pure returns (bytes32) {
        return Bitmap.setBit(bitmap, index, setOn);
    }

    function isBitSet(bytes32 bitmap, uint256 index) public pure returns (bool) {
        return Bitmap.isBitSet(bitmap, index);
    }

    function totalBitsSet(bytes32 bitmap) public pure returns (uint256) {
        return Bitmap.totalBitsSet(bitmap);
    }

    function getMSB(uint256 x) public pure returns (uint256 msb) {
        return Bitmap.getMSB(x);
    }

    function getNextBitNum(bytes32 bitmap) public pure returns (uint256 bitNum) {
        return Bitmap.getNextBitNum(bitmap);
    }

    function bytesToUint(bytes32 bitmap) public pure returns (uint256) {
        return uint256(bitmap);
    }

    function uintToBytes(uint256 bitmap) public pure returns (bytes32) {
        return bytes32(bitmap);
    }

    function naiveCountBits(bytes32 bitmap) public pure returns (uint256) {
        uint256 totalBits;
        for (uint256 i; i < 256; i++) {
            if (bitmap & bytes32(1 << i) != 0x00) totalBits++;
        }

        return totalBits;
    }

    ///////////// Floating 56 //////////////////
    function packTo56Bits(uint256 value) public pure returns (bytes32) {
        return FloatingPoint56.packTo56Bits(value);
    }

    function unpackFrom56Bits(uint256 value) public pure returns (uint256) {
        return FloatingPoint56.unpackFrom56Bits(value);
    }

    ///////////// Asset Rate //////////////////
    function getMinRate(uint8 decimals) public pure returns (int256) {
        return int256(10**decimals * 10 ** 10);
    }

    function isGTE(int256 x, int256 y) public pure returns (bool) {
        return x >= y;
    }

    function isLT(int256 x, int256 y) public pure returns (bool) {
        return x < y;
    }

    function convertToUnderlying(
        int256 rate,
        int256 balance,
        uint8 decimals
    ) public pure returns (int256) {
        AssetRateParameters memory ar = AssetRateParameters(address(0), rate, int256(10**decimals));
        return AssetRate.convertToUnderlying(ar, balance);
    }

    function convertFromUnderlying(
        int256 rate,
        int256 balance,
        uint8 decimals
    ) public pure returns (int256) {
        AssetRateParameters memory ar = AssetRateParameters(address(0), rate, int256(10**decimals));
        return AssetRate.convertFromUnderlying(ar, balance);
    }

    ///////////// Exchange Rate //////////////////
    function convertToETH(
        int256 rate,
        int256 balance,
        uint8 decimals,
        int256 buffer,
        int256 haircut
    ) public pure returns (int256) {
        ETHRate memory er = ETHRate(int256(10**decimals), rate, buffer, haircut, 0);

        return ExchangeRate.convertToETH(er, balance);
    }

    function convertETHTo(
        int256 rate,
        int256 balance,
        uint8 decimals,
        int256 buffer,
        int256 haircut
    ) public pure returns (int256) {
        ETHRate memory er = ETHRate(int256(10**decimals), rate, buffer, haircut, 0);

        return ExchangeRate.convertETHTo(er, balance);
    }

    ///////////// Incentives //////////////////
    function calculateIncentivesToClaim(
        address tokenAddress,
        uint256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 lastClaimIntegralSupply,
        uint256 blockTime,
        uint256 integralTotalSupply,
        uint32 emissionRate
    ) public returns (uint256) {
        nTokenHandler.setIncentiveEmissionRate(tokenAddress, emissionRate);

        return
            Incentives.calculateIncentivesToClaim(
                tokenAddress,
                nTokenBalance,
                lastClaimTime,
                lastClaimIntegralSupply,
                blockTime,
                integralTotalSupply
            );
    }
}
