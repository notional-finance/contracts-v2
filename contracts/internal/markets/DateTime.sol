// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../global/Constants.sol";

library DateTime {
    /// @notice Returns the current reference time which is how all the AMM dates are calculated.
    function getReferenceTime(uint256 blockTime) internal pure returns (uint256) {
        require(blockTime > Constants.QUARTER);
        return blockTime - (blockTime % Constants.QUARTER);
    }

    /// @notice Truncates a date to midnight UTC time
    function getTimeUTC0(uint256 time) internal pure returns (uint256) {
        require(time > Constants.DAY);
        return time - (time % Constants.DAY);
    }

    /// @notice These are the predetermined market offsets for trading
    /// @dev Markets are 1-indexed because the 0 index means that no markets are listed for the cash group.
    function getTradedMarket(uint256 index) internal pure returns (uint256) {
        require(index != 0); // dev: get traded market index is zero

        if (index == 1) return Constants.QUARTER;
        if (index == 2) return 2 * Constants.QUARTER;
        if (index == 3) return Constants.YEAR;
        if (index == 4) return 2 * Constants.YEAR;
        if (index == 5) return 5 * Constants.YEAR;
        if (index == 6) return 10 * Constants.YEAR;
        if (index == 7) return 20 * Constants.YEAR;

        revert("CG: invalid index");
    }

    /// @notice Given a bit number and the reference time of the first bit, returns the bit number
    /// of a given maturity.
    /// @return bitNum and a true or false if the maturity falls on the exact bit
    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        internal
        pure
        returns (uint256, bool)
    {
        uint256 blockTimeUTC0 = getTimeUTC0(blockTime);

        if (maturity % Constants.DAY != 0) return (0, false);
        if (blockTimeUTC0 >= maturity) return (0, false);

        // Overflow check done above
        uint256 daysOffset = (maturity - blockTimeUTC0) / Constants.DAY;

        // These if statements need to fall through to the next one
        if (daysOffset <= Constants.MAX_DAY_OFFSET) {
            return (daysOffset, true);
        }

        if (daysOffset <= Constants.MAX_WEEK_OFFSET) {
            uint256 offset =
                daysOffset -
                    Constants.MAX_DAY_OFFSET +
                    (blockTimeUTC0 % Constants.WEEK) /
                    Constants.DAY;
            // Ensures that the maturity specified falls on the actual day, otherwise division
            // will truncate it
            return (Constants.WEEK_BIT_OFFSET + offset / 6, (offset % 6) == 0);
        }

        if (daysOffset <= Constants.MAX_MONTH_OFFSET) {
            uint256 offset =
                daysOffset -
                    Constants.MAX_WEEK_OFFSET +
                    (blockTimeUTC0 % Constants.MONTH) /
                    Constants.DAY;

            return (Constants.MONTH_BIT_OFFSET + offset / 30, (offset % 30) == 0);
        }

        if (daysOffset <= Constants.MAX_QUARTER_OFFSET) {
            uint256 offset =
                daysOffset -
                    Constants.MAX_MONTH_OFFSET +
                    (blockTimeUTC0 % Constants.QUARTER) /
                    Constants.DAY;

            return (Constants.QUARTER_BIT_OFFSET + offset / 90, (offset % 90) == 0);
        }

        // This is the maximum 1-indexed bit num
        return (256, false);
    }

    /// @notice Given a bit number and a block time returns the maturity that the bit number
    /// should reference. Bit numbers are one indexed.
    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        internal
        pure
        returns (uint256)
    {
        require(bitNum != 0); // dev: cash group get maturity from bit num is zero
        require(bitNum <= 256); // dev: cash group get maturity from bit num overflow
        uint256 blockTimeUTC0 = getTimeUTC0(blockTime);
        uint256 firstBit;

        if (bitNum <= Constants.WEEK_BIT_OFFSET) {
            return blockTimeUTC0 + bitNum * Constants.DAY;
        }

        if (bitNum <= Constants.MONTH_BIT_OFFSET) {
            firstBit =
                blockTimeUTC0 +
                Constants.MAX_DAY_OFFSET *
                Constants.DAY -
                (blockTimeUTC0 % Constants.WEEK);
            return firstBit + (bitNum - Constants.WEEK_BIT_OFFSET) * Constants.WEEK;
        }

        if (bitNum <= Constants.QUARTER_BIT_OFFSET) {
            firstBit =
                blockTimeUTC0 +
                Constants.MAX_WEEK_OFFSET *
                Constants.DAY -
                (blockTimeUTC0 % Constants.MONTH);
            return firstBit + (bitNum - Constants.MONTH_BIT_OFFSET) * Constants.MONTH;
        }

        firstBit =
            blockTimeUTC0 +
            Constants.MAX_MONTH_OFFSET *
            Constants.DAY -
            (blockTimeUTC0 % Constants.QUARTER);
        return firstBit + (bitNum - Constants.QUARTER_BIT_OFFSET) * Constants.QUARTER;
    }
}
