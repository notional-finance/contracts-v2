// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "./Market.sol";
import "./AssetRate.sol";
import "../storage/StorageLayoutV1.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @dev Cash group when loaded into memory
 */
struct CashGroupParameters {
    uint currencyId;
    uint maxMarketIndex;
    AssetRateParameters assetRate;
    bytes32 data;
}

library CashGroup {
    using SafeMath for uint256;
    using SafeInt256 for int;
    using AssetRate for AssetRateParameters;
    using Market for MarketParameters;

    uint internal constant CASH_GROUP_STORAGE_SLOT = 3;

    // Offsets for the bytes of the different parameters
    // TODO: benchmark if the current method is better than just allocating them to memory
    uint internal constant RATE_ORACLE_TIME_WINDOW = 8;
    uint internal constant LIQUIDITY_FEE = 16;
    uint internal constant LIQUIDITY_TOKEN_HAIRCUT = 24;
    uint internal constant DEBT_BUFFER = 32;
    uint internal constant FCASH_HAIRCUT = 40;
    uint internal constant RATE_SCALAR = 48;

    uint internal constant DAY = 86400;
    // We use six day weeks to ensure that all time references divide evenly
    uint internal constant WEEK = DAY * 6;
    uint internal constant MONTH = DAY * 30;
    uint internal constant QUARTER = DAY * 90;
    uint internal constant YEAR = QUARTER * 4;

    // Max offsets used for bitmap
    uint internal constant MAX_DAY_OFFSET = 90;
    uint internal constant MAX_WEEK_OFFSET = 360;
    uint internal constant MAX_MONTH_OFFSET = 2160;
    uint internal constant MAX_QUARTER_OFFSET = 7650;
    uint internal constant WEEK_BIT_OFFSET = 90;
    uint internal constant MONTH_BIT_OFFSET = 135;
    uint internal constant QUARTER_BIT_OFFSET = 195;
    int internal constant TOKEN_HAIRCUT_DECIMALS = 100;
    int internal constant TOKEN_REPO_INCENTIVE = 10;
    uint internal constant MAX_TRADED_MARKET_INDEX = 9;


    /**
     * @notice These are the predetermined market offsets for trading, they are 1-indexed because
     * the 0 index means that no markets are listed for the cash group.
     * @dev This is a function because array types are not allowed to be constants yet.
     */
    function getTradedMarket(uint index) internal pure returns (uint) {
        require(index != 0);

        if (index == 1) return QUARTER;
        if (index == 2) return 2 * QUARTER;
        if (index == 3) return YEAR;
        if (index == 4) return 2 * YEAR;
        if (index == 5) return 5 * YEAR;
        if (index == 6) return 7 * YEAR;
        if (index == 7) return 10 * YEAR;
        if (index == 8) return 15 * YEAR;
        if (index == 9) return 20 * YEAR;

        revert("CG: invalid index");
    }

    /**
     * @notice Returns the current reference time which is how all the AMM dates are
     * calculated.
     */
    function getReferenceTime(uint blockTime) internal pure returns (uint) {
        return blockTime.sub(blockTime % QUARTER);
    }

    /**
     * @notice Truncates a date to midnight UTC time
     */
    function getTimeUTC0(uint time) internal pure returns (uint) {
        return time.sub(time % DAY);
    }

    /**
     * @notice Determines if the maturity falls on one of the valid on chain market dates.
     */
    function isValidMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) internal pure returns (bool) {
        uint maxMarketIndex = cashGroup.maxMarketIndex;
        require(maxMarketIndex > 0, "CG: no markets listed");
        require(maxMarketIndex < 10, "CG: market index bound");

        if (maturity % QUARTER != 0) return false;
        uint tRef = getReferenceTime(blockTime);

        for (uint i = 1; i <= maxMarketIndex; i++) {
            if (maturity == tRef.add(getTradedMarket(i))) return true;
        }

        return false;
    }

    /**
     * @notice Determines if an idiosyncratic maturity is valid and returns the bit reference
     * that is the case.
     *
     * @return True or false if the maturity is valid
     */
    function isValidIdiosyncraticMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) internal pure returns (bool) {
        uint tRef = getReferenceTime(blockTime);
        uint maxMaturity = tRef.add(getTradedMarket(cashGroup.maxMarketIndex));
        if (maturity > maxMaturity) return false;

        (/* */, bool isValid) = getBitNumFromMaturity(blockTime, maturity);
        return isValid;
    }

    /**
     * @notice Given a bit number and the reference time of the first bit, returns the bit number
     * of a given maturity.
     *
     * @return bitNum and a true or false if the maturity falls on the exact bit
     */
    function getBitNumFromMaturity(
       uint blockTime,
       uint maturity
    ) internal pure returns (uint, bool) {
        uint blockTimeUTC0 = getTimeUTC0(blockTime);

        if (maturity % DAY != 0) return (0, false);
        if (blockTimeUTC0 >= maturity) return (0, false);

        // Overflow check done above
        uint daysOffset = (maturity - blockTimeUTC0) / DAY;

        // These if statements need to fall through to the next one
        if (daysOffset <= MAX_DAY_OFFSET) {
            return (daysOffset, true);
        }

        if (daysOffset <= MAX_WEEK_OFFSET) {
            uint offset = daysOffset - MAX_DAY_OFFSET + (blockTimeUTC0 % WEEK) / DAY;
            // Ensures that the maturity specified falls on the actual day, otherwise division
            // will truncate it
            return (WEEK_BIT_OFFSET + offset / 6, (offset % 6) == 0);
        }

        if (daysOffset <= MAX_MONTH_OFFSET) {
            uint offset = daysOffset - MAX_WEEK_OFFSET + (blockTimeUTC0 % MONTH) / DAY;

            return (MONTH_BIT_OFFSET + offset / 30, (offset % 30) == 0);
        }

        if (daysOffset <= MAX_QUARTER_OFFSET) {
            uint offset = daysOffset - MAX_MONTH_OFFSET + (blockTimeUTC0 % QUARTER) / DAY;

            return (QUARTER_BIT_OFFSET + offset / 90, (offset % 90) == 0);
        }

        // This is the maximum 1-indexed bit num
        return (256, false);
    }

    /**
     * @notice Given a bit number and a block time returns the maturity that the bit number
     * should reference. Bit numbers are one indexed.
     */
    function getMaturityFromBitNum(
        uint blockTime,
        uint bitNum
    ) internal pure returns (uint) {
        require(bitNum != 0, "CG: bit num underflow");
        require(bitNum <= 256, "CG: bit num overflow");
        uint blockTimeUTC0 = getTimeUTC0(blockTime);
        uint firstBit;

        if (bitNum <= WEEK_BIT_OFFSET) {
            return blockTimeUTC0 + bitNum * DAY;
        }

        if (bitNum <= MONTH_BIT_OFFSET) {
            firstBit = blockTimeUTC0 + MAX_DAY_OFFSET * DAY - (blockTimeUTC0 % WEEK);
            return firstBit + (bitNum - WEEK_BIT_OFFSET) * WEEK;
        }

        if (bitNum <= QUARTER_BIT_OFFSET) {
            firstBit = blockTimeUTC0 + MAX_WEEK_OFFSET * DAY - (blockTimeUTC0 % MONTH);
            return firstBit + (bitNum - MONTH_BIT_OFFSET) * MONTH;
        }

        firstBit = blockTimeUTC0 + MAX_MONTH_OFFSET * DAY - (blockTimeUTC0 % QUARTER);
        return firstBit + (bitNum - QUARTER_BIT_OFFSET) * QUARTER;
    }

    /**
     * @notice Returns the rate scalar scaled by time to maturity. The rate scalar multiplies
     * the ln() portion of the liquidity curve as an inverse so it increases with time to 
     * maturity. The effect of the rate scalar on slippage must decrease with time to maturity.
     */
    function getRateScalar(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) internal pure returns (int) {
        int scalar = int(uint16(uint(cashGroup.data >> RATE_SCALAR)));
        int rateScalar = scalar
            .mul(int(Market.IMPLIED_RATE_TIME))
            .div(int(timeToMaturity));

        require(rateScalar > 0, "CG: rate scalar underflow");
        return rateScalar;
    }

    function annualizeUintValue(
        uint value,
        uint timeToMaturity
    ) private pure returns (uint) {
        return value.mul(timeToMaturity).div(Market.IMPLIED_RATE_TIME);
    }
    
    /**
     * @notice Returns liquidity fees scaled by time to maturity. The liquidity fee is denominated
     * in basis points and will decrease with time to maturity.
     */
    function getLiquidityFee(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) internal pure returns (uint) {
        uint liquidityFee = uint(uint8(uint(cashGroup.data >> LIQUIDITY_FEE))) * Market.BASIS_POINT;
        return annualizeUintValue(liquidityFee, timeToMaturity);
    }

    function getLiquidityHaircut(
        CashGroupParameters memory cashGroup,
        uint /* timeToMaturity */
    ) internal pure returns (uint) {
        // TODO: unclear how this should be calculated
        uint liquidityTokenHaircut = uint(uint8(uint(cashGroup.data >> LIQUIDITY_TOKEN_HAIRCUT)));
        return liquidityTokenHaircut;
    }

    function getfCashHaircut(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        // TODO: unclear how this should be calculated
        return uint(uint8(uint(cashGroup.data >> FCASH_HAIRCUT))) * Market.BASIS_POINT;
    }

    function getDebtBuffer(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(uint(cashGroup.data >> DEBT_BUFFER))) * Market.BASIS_POINT;
    }

    function getRateOracleTimeWindow(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        // This is denominated in minutes in storage
        return uint(uint8(uint(cashGroup.data >> RATE_ORACLE_TIME_WINDOW))) * 60;
    }

    function getMarketIndex(
        CashGroupParameters memory cashGroup,
        uint maturity,
        uint blockTime
    ) internal pure returns (uint, bool) {
        uint maxMarketIndex = cashGroup.maxMarketIndex;
        require(maxMarketIndex > 0, "CG: no markets listed");
        require(maxMarketIndex < 10, "CG: market index bound");
        uint tRef = getReferenceTime(blockTime);

        for (uint i = 1; i <= maxMarketIndex; i++) {
            uint marketMaturity = tRef.add(getTradedMarket(i));
            if (marketMaturity == maturity) return (i, false);
            if (marketMaturity > maturity) return (i, true);
        }

        revert("CG: no market found");
    }

    function getMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint marketIndex,
        uint blockTime,
        bool needsLiquidity
    ) internal view returns (MarketParameters memory) {
        require(marketIndex > 0, "C: invalid market index");
        require(marketIndex <= markets.length, "C: invalid market index");
        MarketParameters memory market = markets[marketIndex - 1];

        // TODO: maybe change this to a bool, hasLoaded
        if (market.currencyId == 0) {
            uint maturity = getReferenceTime(blockTime).add(getTradedMarket(marketIndex));
            market = Market.buildMarket(
                cashGroup.currencyId,
                maturity,
                blockTime,
                needsLiquidity,
                getRateOracleTimeWindow(cashGroup)
            );
            // TODO: maybe change this so that a new allocation is not made?
            // Set this here because buildMarket returns a new allocation
            markets[marketIndex - 1] = market;
        }

        if (market.totalLiquidity == 0 && needsLiquidity) {
            // Fetch liquidity amount
            uint settlementDate = getReferenceTime(blockTime);
            market.getTotalLiquidity(settlementDate);
        }

        return market;
    }

    /**
     * @notice Returns the linear interpolation between two market rates. The formula is
     * slope = (longMarket.oracleRate - shortMarket.oracleRate) / (longMarket.maturity - shortMarket.maturity)
     * interpolatedRate = slope * (assetMaturity - shortMarket.maturity) + shortMarket.oracleRate
     */
    function interpolateOracleRate(
        uint shortMaturity,
        uint longMaturity,
        uint shortRate,
        uint longRate,
        uint assetMaturity
    ) internal pure returns (uint) {
        require(shortMaturity < assetMaturity, "CG: interpolation error");
        require(assetMaturity < longMaturity, "CG: interpolation error");

        // It's possible that the rates are inverted where the short market rate > long market rate and
        // we will get underflows here so we check for that
        if (longRate >= shortRate) {
            return (longRate - shortRate)
                .mul(assetMaturity - shortMaturity)
                // No underflow here, checked above
                .div(longMaturity - shortMaturity)
                .add(shortRate);
        } else {
            // In this case the slope is negative so:
            // interpolatedRate = shortMarket.oracleRate - slope * (assetMaturity - shortMarket.maturity)
            return shortRate.sub(
                // This is reversed to keep it it positive
                (shortRate - longRate)
                    .mul(assetMaturity - shortMaturity)
                    // No underflow here, checked above
                    .div(longMaturity - shortMaturity)
            );
        }
    }

    function getOracleRate(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint assetMaturity,
        uint blockTime
    ) internal view returns (uint) {
        (uint marketIndex, bool idiosyncractic) = getMarketIndex(cashGroup, assetMaturity, blockTime);
        MarketParameters memory market = getMarket(cashGroup, markets, marketIndex, blockTime, false);

        // TODO: need to review if this is the correct thing to do, we know that this will not include
        // matured assets, therefore marketIndex != 1 if we hit this point.
        if (market.oracleRate == 0) {
            // If oracleRate is zero then the market has not been initialized
            // and we want to reference the previous market for interpolating rates.
            uint prevBlockTime = blockTime.sub(CashGroup.QUARTER);
            uint maturity = getReferenceTime(prevBlockTime).add(getTradedMarket(marketIndex));
            market = Market.buildMarket(
                cashGroup.currencyId,
                maturity,
                prevBlockTime,
                false,
                getRateOracleTimeWindow(cashGroup)
            );
        }
        require(market.oracleRate != 0, "C: market not initialized");

        if (!idiosyncractic) return market.oracleRate;

        if (marketIndex == 1) {
            // In this case the short market is the annualized asset supply rate
            return interpolateOracleRate(
                blockTime,
                market.maturity,
                cashGroup.assetRate.getSupplyRate(),
                market.oracleRate,
                assetMaturity
            );
        }

        MarketParameters memory shortMarket = getMarket(cashGroup, markets, marketIndex - 1, blockTime, false);
        return interpolateOracleRate(
            shortMarket.maturity,
            market.maturity,
            shortMarket.oracleRate,
            market.oracleRate,
            assetMaturity
        );
    }

    function getCashGroupStorageBytes(uint currencyId) private view returns(bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, CASH_GROUP_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        // bytes memory would be cleaner here but solidity does not support that inside struct
        return data;
    }

    /**
     * @notice Converts cash group storage object into memory object
     */
    function buildCashGroup(
        uint currencyId
    ) internal view returns (CashGroupParameters memory, MarketParameters[] memory) {
        bytes32 data = getCashGroupStorageBytes(currencyId);
        // Ensure that accrue interest is called at the beginning of every method before this rate
        // is built otherwise this wont be the most up to date interest rate.
        AssetRateParameters memory assetRate = AssetRate.buildAssetRate(currencyId);
        uint maxMarketIndex = uint(uint8(uint(data)));

        return (
            CashGroupParameters({
                currencyId: currencyId,
                maxMarketIndex: maxMarketIndex,
                assetRate: assetRate,
                data: data
            }),
            // It would be nice to nest this inside cash group parameters
            // but there are issues with circular imports perhaps.
            new MarketParameters[](maxMarketIndex)
        );
    }

}
