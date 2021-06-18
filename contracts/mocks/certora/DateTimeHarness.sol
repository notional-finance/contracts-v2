// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/DateTime.sol";

contract DateTimeHarness {
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
}
