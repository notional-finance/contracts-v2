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

    // Offsets for the bytes of the different parameters
    uint internal constant RATE_ORACLE_TIME_WINDOW = 8;
    uint internal constant TOTAL_FEE = 16;
    uint internal constant RESERVE_FEE_SHARE = 24;
    uint internal constant DEBT_BUFFER = 32;
    uint internal constant FCASH_HAIRCUT = 40;
    uint internal constant SETTLEMENT_PENALTY = 48;
    uint internal constant LIQUIDATION_FCASH_HAIRCUT = 56;
    // 9 bytes allocated per market on the liquidity token haircut
    uint internal constant LIQUIDITY_TOKEN_HAIRCUT = 64;
    // 9 bytes allocated per market on the rate scalar
    uint internal constant RATE_SCALAR = 136;

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
    int internal constant PERCENTAGE_DECIMALS = 100;
    uint internal constant MAX_TRADED_MARKET_INDEX = 9;


    /**
     * @notice These are the predetermined market offsets for trading, they are 1-indexed because
     * the 0 index means that no markets are listed for the cash group.
     * @dev This is a function because array types are not allowed to be constants yet.
     */
    function getTradedMarket(uint index) internal pure returns (uint) {
        require(index != 0); // dev: get traded market index is zero

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
        require(bitNum != 0); // dev: cash group get maturity from bit num is zero
        require(bitNum <= 256); // dev: cash group get maturity from bit num overflow
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
        uint marketIndex,
        uint timeToMaturity
    ) internal pure returns (int) {
        require(marketIndex >= 1); // dev: invalid market index
        uint offset = RATE_SCALAR + 8 * (marketIndex - 1);
        int scalar = int(uint8(uint(cashGroup.data >> offset))) * 10;
        int rateScalar = scalar
            .mul(int(Market.IMPLIED_RATE_TIME))
            .div(int(timeToMaturity));

        require(rateScalar > 0, "CG: rate scalar underflow");
        return rateScalar;
    }

    /**
     * @notice Haircut on liquidity tokens to account for the risk associated with changes in the
     * proportion of cash to fCash within the pool. This is set as a percentage less than or equal to 100.
     */
    function getLiquidityHaircut(
        CashGroupParameters memory cashGroup,
        uint assetType
    ) internal pure returns (uint) {
        require(assetType > 1); // dev: liquidity haircut invalid asset type
        uint offset = LIQUIDITY_TOKEN_HAIRCUT + 8 * (assetType - 2);
        uint liquidityTokenHaircut = uint(uint8(uint(cashGroup.data >> offset)));
        return liquidityTokenHaircut;
    }

    function getTotalFee(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(uint(cashGroup.data >> TOTAL_FEE))) * Market.BASIS_POINT;
    }

    function getReserveFeeShare(
        CashGroupParameters memory cashGroup
    ) internal pure returns (int) {
        return int(uint8(uint(cashGroup.data >> RESERVE_FEE_SHARE)));
    }

    function getfCashHaircut(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(uint(cashGroup.data >> FCASH_HAIRCUT))) * (5 * Market.BASIS_POINT);
    }

    function getDebtBuffer(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(uint(cashGroup.data >> DEBT_BUFFER))) * (5 * Market.BASIS_POINT);
    }

    function getRateOracleTimeWindow(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        // This is denominated in minutes in storage
        return uint(uint8(uint(cashGroup.data >> RATE_ORACLE_TIME_WINDOW))) * 60;
    }

    function getSettlementPenalty(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(uint(cashGroup.data >> SETTLEMENT_PENALTY))) * (5 * Market.BASIS_POINT);
    }

    function getLiquidationfCashHaircut(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(uint(cashGroup.data >> LIQUIDATION_FCASH_HAIRCUT))) * (5 * Market.BASIS_POINT);
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

        if (market.storageSlot == 0) {
            uint maturity = getReferenceTime(blockTime).add(getTradedMarket(marketIndex));
            market.loadMarket(
                cashGroup.currencyId,
                maturity,
                blockTime,
                needsLiquidity,
                getRateOracleTimeWindow(cashGroup)
            );
        }

        if (market.totalLiquidity == 0 && needsLiquidity) {
            market.getTotalLiquidity();
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
        require(shortMaturity < assetMaturity); // dev: cash group interpolation error, short maturity
        require(assetMaturity < longMaturity); // dev: cash group interpolation error, long maturity

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
            // NOTE: this subtraction should never overflow, the linear interpolation between two points above zero
            // cannot go below zero
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
            market.loadMarket(
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

    function getCashGroupStorageBytes(uint currencyId) internal view returns(bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, "cashgroup"));
        bytes32 data;

        assembly { data := sload(slot) }

        return data;
    }

    function setCashGroupStorage(
        uint currencyId,
        CashGroupParameterStorage calldata cashGroup
    ) internal {
        bytes32 slot = keccak256(abi.encode(currencyId, "cashgroup"));
        require(
            cashGroup.maxMarketIndex >= 0 && cashGroup.maxMarketIndex <= CashGroup.MAX_TRADED_MARKET_INDEX,
            "CG: invalid market index"
        );
        // Due to the requirements of the yield curve we do not allow a cash group to have solely a 3 month market.
        // The reason is that borrowers will not have a futher maturity to roll from their 3 month fixed to a 6 month
        // fixed. It also complicates the logic in the perpetual token initialization method
        require(cashGroup.maxMarketIndex != 1, "CG: invalid market index");
        require(cashGroup.reserveFeeShare <= CashGroup.PERCENTAGE_DECIMALS, "CG: invalid reserve share");
        require(cashGroup.liquidityTokenHaircuts.length == cashGroup.maxMarketIndex);
        require(cashGroup.rateScalars.length == cashGroup.maxMarketIndex);

        // Market indexes cannot decrease or they will leave fCash assets stranded in the future with no valuation curve
        uint8 previousMaxMarketIndex = uint8(uint(getCashGroupStorageBytes(currencyId)));
        require(previousMaxMarketIndex <= cashGroup.maxMarketIndex, "CG: market index cannot decrease");

        // Per cash group settings
        bytes32 data = (
            bytes32(uint(cashGroup.maxMarketIndex)) |
            bytes32(uint(cashGroup.rateOracleTimeWindowMin)) << RATE_ORACLE_TIME_WINDOW |
            bytes32(uint(cashGroup.totalFeeBPS)) << TOTAL_FEE |
            bytes32(uint(cashGroup.reserveFeeShare)) << RESERVE_FEE_SHARE |
            bytes32(uint(cashGroup.debtBuffer5BPS)) << DEBT_BUFFER |
            bytes32(uint(cashGroup.fCashHaircut5BPS)) << FCASH_HAIRCUT |
            bytes32(uint(cashGroup.settlementPenaltyRateBPS)) << SETTLEMENT_PENALTY |
            bytes32(uint(cashGroup.liquidationfCashHaircut5BPS)) << LIQUIDATION_FCASH_HAIRCUT
        );

        // Per market group settings
        for (uint i; i < cashGroup.liquidityTokenHaircuts.length; i++) {
            require(
                cashGroup.liquidityTokenHaircuts[i] <= CashGroup.PERCENTAGE_DECIMALS,
                "CG: invalid token haircut"
            );

            data = data | bytes32(uint(cashGroup.liquidityTokenHaircuts[i])) << LIQUIDITY_TOKEN_HAIRCUT + i * 8;
        }

        for (uint i; i < cashGroup.rateScalars.length; i++) {
            // Causes a divide by zero error
            require(cashGroup.rateScalars[i] != 0, "CG: invalid rate scalar");
            data = data | bytes32(uint(cashGroup.rateScalars[i])) << RATE_SCALAR + i * 8;
        }

        assembly { sstore(slot, data) }
    }

    function deserializeCashGroupStorage(
        uint currencyId
    ) internal view returns (CashGroupParameterStorage memory) {
        bytes32 data = getCashGroupStorageBytes(currencyId);
        uint8 maxMarketIndex = uint8(data[31]);
        uint8[] memory tokenHaircuts = new uint8[](uint(maxMarketIndex));
        uint8[] memory rateScalars = new uint8[](uint(maxMarketIndex));

        for (uint8 i; i < maxMarketIndex; i++) {
            tokenHaircuts[i] = uint8(data[23 - i]);
            rateScalars[i] = uint8(data[14 - i]);
        }

        return CashGroupParameterStorage({
            maxMarketIndex: maxMarketIndex,
            rateOracleTimeWindowMin: uint8(data[30]),
            totalFeeBPS: uint8(data[29]),
            reserveFeeShare: uint8(data[28]),
            debtBuffer5BPS: uint8(data[27]),
            fCashHaircut5BPS: uint8(data[26]),
            settlementPenaltyRateBPS: uint8(data[25]),
            liquidationfCashHaircut5BPS: uint8(data[24]),
            liquidityTokenHaircuts: tokenHaircuts,
            rateScalars: rateScalars
        });
    }

    function buildCashGroupInternal(
        uint currencyId,
        AssetRateParameters memory assetRate
    ) private view returns (CashGroupParameters memory, MarketParameters[] memory) {
        bytes32 data = getCashGroupStorageBytes(currencyId);
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

    /**
     * @notice Converts cash group storage object into memory object
     */
    function buildCashGroupView(
        uint currencyId
    ) internal view returns (CashGroupParameters memory, MarketParameters[] memory) {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateView(currencyId);
        return buildCashGroupInternal(currencyId, assetRate);
    }

    function buildCashGroupStateful(
        uint currencyId
    ) internal returns (CashGroupParameters memory, MarketParameters[] memory) {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(currencyId);
        return buildCashGroupInternal(currencyId, assetRate);
    }

}
