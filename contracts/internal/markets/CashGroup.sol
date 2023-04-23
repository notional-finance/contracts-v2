// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    CashGroupParameters,
    CashGroupSettings,
    MarketParameters,
    PrimeRate
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {Market} from "./Market.sol";
import {DateTime} from "./DateTime.sol";

library CashGroup {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using Market for MarketParameters;

    // Bit number references for each parameter in the 32 byte word (0-indexed)
    uint256 private constant MARKET_INDEX_BIT = 31;
    uint256 private constant RATE_ORACLE_TIME_WINDOW_BIT = 30;
    uint256 private constant MAX_DISCOUNT_FACTOR_BIT = 29;
    uint256 private constant RESERVE_FEE_SHARE_BIT = 28;
    uint256 private constant DEBT_BUFFER_BIT = 27;
    uint256 private constant FCASH_HAIRCUT_BIT = 26;
    uint256 private constant _DEPRECATED_BIT = 25;
    uint256 private constant LIQUIDATION_FCASH_HAIRCUT_BIT = 24;
    uint256 private constant LIQUIDATION_DEBT_BUFFER_BIT = 23;
    // 7 bytes allocated, one byte per market for the min oracle rate
    uint256 private constant MIN_ORACLE_RATE_FIRST_BIT = 22;
    // 7 bytes allocated, one byte per market for the max oracle rate
    uint256 private constant MAX_ORACLE_RATE_FIRST_BIT = 15; 

    // Offsets for the bytes of the different parameters
    uint256 private constant MARKET_INDEX = (31 - MARKET_INDEX_BIT) * 8;
    uint256 private constant RATE_ORACLE_TIME_WINDOW = (31 - RATE_ORACLE_TIME_WINDOW_BIT) * 8;
    uint256 private constant MAX_DISCOUNT_FACTOR = (31 - MAX_DISCOUNT_FACTOR_BIT) * 8;
    uint256 private constant RESERVE_FEE_SHARE = (31 - RESERVE_FEE_SHARE_BIT) * 8;
    uint256 private constant DEBT_BUFFER = (31 - DEBT_BUFFER_BIT) * 8;
    uint256 private constant FCASH_HAIRCUT = (31 - FCASH_HAIRCUT_BIT) * 8;
    uint256 private constant _DEPRECATED_SETTLEMENT_PENALTY = (31 - _DEPRECATED_BIT) * 8;
    uint256 private constant LIQUIDATION_FCASH_HAIRCUT = (31 - LIQUIDATION_FCASH_HAIRCUT_BIT) * 8;
    uint256 private constant LIQUIDATION_DEBT_BUFFER = (31 - LIQUIDATION_DEBT_BUFFER_BIT) * 8;
    uint256 private constant MIN_ORACLE_RATE = (31 - MIN_ORACLE_RATE_FIRST_BIT) * 8;
    uint256 private constant MAX_ORACLE_RATE = (31 - MAX_ORACLE_RATE_FIRST_BIT) * 8;

    function getMaxDiscountFactor(CashGroupParameters memory cashGroup)
        internal pure returns (int256)
    {
        uint256 maxDiscountFactor = uint256(uint8(uint256(cashGroup.data >> MAX_DISCOUNT_FACTOR))) * Constants.BASIS_POINT;
        // Overflow/Underflow is not possible due to storage size limits
        return Constants.RATE_PRECISION - int256(maxDiscountFactor);
    }

    function getMinOracleRate(CashGroupParameters memory cashGroup, uint256 marketIndex)
        internal pure returns (uint256)
    {
        require(0 < marketIndex);
        require(marketIndex <= Constants.MAX_TRADED_MARKET_INDEX);
        uint256 offset = MIN_ORACLE_RATE + 8 * (marketIndex - 1);
        return uint256(uint8(uint256(cashGroup.data >> offset))) * Constants.FIVE_BASIS_POINTS;
    }

    function getMaxOracleRate(CashGroupParameters memory cashGroup, uint256 marketIndex)
        internal pure returns (uint256)
    {
        require(0 < marketIndex);
        require(marketIndex <= Constants.MAX_TRADED_MARKET_INDEX);
        uint256 offset = MAX_ORACLE_RATE + 8 * (marketIndex - 1);
        return uint256(uint8(uint256(cashGroup.data >> offset))) * Constants.FIFTEEN_BASIS_POINTS;
    }

    /// @notice Percentage of the total trading fee that goes to the reserve
    function getReserveFeeShare(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (int256)
    {
        return uint8(uint256(cashGroup.data >> RESERVE_FEE_SHARE));
    }

    /// @notice fCash haircut for valuation denominated in rate precision with five basis point increments
    function getfCashHaircut(CashGroupParameters memory cashGroup) internal pure returns (uint256) {
        return
            uint256(uint8(uint256(cashGroup.data >> FCASH_HAIRCUT))) * Constants.FIVE_BASIS_POINTS;
    }

    /// @notice fCash debt buffer for valuation denominated in rate precision with five basis point increments
    function getDebtBuffer(CashGroupParameters memory cashGroup) internal pure returns (uint256) {
        return uint256(uint8(uint256(cashGroup.data >> DEBT_BUFFER))) * Constants.FIVE_BASIS_POINTS;
    }

    /// @notice Time window factor for the rate oracle denominated in seconds with five minute increments.
    function getRateOracleTimeWindow(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        // This is denominated in 5 minute increments in storage
        return uint256(uint8(uint256(cashGroup.data >> RATE_ORACLE_TIME_WINDOW))) * Constants.FIVE_MINUTES;
    }

    /// @notice Haircut for positive fCash during liquidation denominated rate precision
    /// with five basis point increments
    function getLiquidationfCashHaircut(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        return
            uint256(uint8(uint256(cashGroup.data >> LIQUIDATION_FCASH_HAIRCUT))) * Constants.FIVE_BASIS_POINTS;
    }

    /// @notice Haircut for negative fCash during liquidation denominated rate precision
    /// with five basis point increments
    function getLiquidationDebtBuffer(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        return
            uint256(uint8(uint256(cashGroup.data >> LIQUIDATION_DEBT_BUFFER))) * Constants.FIVE_BASIS_POINTS;
    }

    function loadMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        uint256 marketIndex,
        bool needsLiquidity,
        uint256 blockTime
    ) internal view {
        require(1 <= marketIndex && marketIndex <= cashGroup.maxMarketIndex, "Invalid market");
        uint256 maturity =
            DateTime.getReferenceTime(blockTime).add(DateTime.getTradedMarket(marketIndex));

        market.loadMarket(
            cashGroup.currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            getRateOracleTimeWindow(cashGroup)
        );
    }

    /// @notice Returns the linear interpolation between two market rates. The formula is
    /// slope = (longMarket.oracleRate - shortMarket.oracleRate) / (longMarket.maturity - shortMarket.maturity)
    /// interpolatedRate = slope * (assetMaturity - shortMarket.maturity) + shortMarket.oracleRate
    function interpolateOracleRate(
        uint256 shortMaturity,
        uint256 longMaturity,
        uint256 shortRate,
        uint256 longRate,
        uint256 assetMaturity
    ) internal pure returns (uint256) {
        require(shortMaturity < assetMaturity); // dev: cash group interpolation error, short maturity
        require(assetMaturity < longMaturity); // dev: cash group interpolation error, long maturity

        // It's possible that the rates are inverted where the short market rate > long market rate and
        // we will get an underflow here so we check for that
        if (longRate >= shortRate) {
            return
                (longRate - shortRate)
                    .mul(assetMaturity - shortMaturity)
                // No underflow here, checked above
                    .div(longMaturity - shortMaturity)
                    .add(shortRate);
        } else {
            // In this case the slope is negative so:
            // interpolatedRate = shortMarket.oracleRate - slope * (assetMaturity - shortMarket.maturity)
            // NOTE: this subtraction should never overflow, the linear interpolation between two points above zero
            // cannot go below zero
            return
                shortRate.sub(
                    // This is reversed to keep it it positive
                    (shortRate - longRate)
                        .mul(assetMaturity - shortMaturity)
                    // No underflow here, checked above
                        .div(longMaturity - shortMaturity)
                );
        }
    }

    function calculateRiskAdjustedfCashOracleRate(
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 blockTime
    ) internal view returns (uint256 oracleRate) {
        uint256 marketIndex; uint256 shortMaturity; uint256 longMaturity;
        (oracleRate, marketIndex, shortMaturity, longMaturity) = _calculateOracleRate(
            cashGroup, maturity, blockTime
        );

        oracleRate = oracleRate.add(getfCashHaircut(cashGroup));
        uint256 minOracleRate;
        if (shortMaturity == 0 || shortMaturity == blockTime) {
            // If short maturity == blockTime then it is a sub 3 month ifCash asset and marketIndex
            // will equal 1 at this point. Use the shortest dated market's oracle rate in that case.
            minOracleRate = getMinOracleRate(cashGroup, marketIndex);
        } else {
            // Use the min oracle rate of whichever market index is closer. No overflows or underflows
            // can happen since maturities are checked in _calculateOracleRate.
            minOracleRate = (maturity - shortMaturity) < (longMaturity - maturity) ?
                getMinOracleRate(cashGroup, marketIndex - 1) :
                getMinOracleRate(cashGroup, marketIndex);
        }

        if (oracleRate < minOracleRate) oracleRate = minOracleRate;
    }

    function calculateRiskAdjustedDebtOracleRate(
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 blockTime
    ) internal view returns (uint256 oracleRate) {
        uint256 marketIndex; uint256 shortMaturity; uint256 longMaturity;
        (oracleRate, marketIndex, shortMaturity, longMaturity) = _calculateOracleRate(
            cashGroup, maturity, blockTime
        );

        uint256 debtBuffer = getDebtBuffer(cashGroup);
        // If the adjustment exceeds the oracle rate we floor the oracle rate at zero,
        // We don't want to require the account to hold more than absolutely required.
        if (oracleRate <= debtBuffer) return 0;

        oracleRate = oracleRate - debtBuffer;
        uint256 maxOracleRate;
        if (shortMaturity == 0 || shortMaturity == blockTime) {
            // If short maturity == blockTime then it is a sub 3 month ifCash asset and marketIndex
            // will equal 1 at this point. Use the shortest dated market's oracle rate in that case.
            maxOracleRate = getMaxOracleRate(cashGroup, marketIndex);
        } else {
            // Use the max oracle rate of whichever market index is closer. No overflows or underflows
            // can happen since maturities are checked in _calculateOracleRate.
            maxOracleRate = (maturity - shortMaturity) < (longMaturity - maturity) ?
                getMaxOracleRate(cashGroup, marketIndex - 1) :
                getMaxOracleRate(cashGroup, marketIndex);
        }

        if (maxOracleRate < oracleRate) oracleRate = maxOracleRate;
    }
    

    /// @dev Gets an oracle rate given any valid maturity.
    function calculateOracleRate(
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 blockTime
    ) internal view returns (uint256) {
        (uint256 oracleRate, /* */, /* */, /* */) = _calculateOracleRate(cashGroup, maturity, blockTime);
        return oracleRate;
    }

    function _calculateOracleRate(
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 blockTime
    ) private view returns (
        uint256 oracleRate,
        uint256 marketIndex,
        uint256 shortMaturity,
        uint256 longMaturity
    ) {
        bool idiosyncratic;
        (marketIndex, idiosyncratic) =
            DateTime.getMarketIndex(cashGroup.maxMarketIndex, maturity, blockTime);
        uint256 timeWindow = getRateOracleTimeWindow(cashGroup);

        if (!idiosyncratic) {
            oracleRate = Market.getOracleRate(cashGroup.currencyId, maturity, timeWindow, blockTime);
        } else {
            uint256 referenceTime = DateTime.getReferenceTime(blockTime);
            // DateTime.getMarketIndex returns the market that is past the maturity if idiosyncratic
            longMaturity = referenceTime.add(DateTime.getTradedMarket(marketIndex));
            uint256 longRate =
                Market.getOracleRate(cashGroup.currencyId, longMaturity, timeWindow, blockTime);

            uint256 shortRate;
            if (marketIndex == 1) {
                // In this case the short market is the annualized asset supply rate
                shortMaturity = blockTime;
                shortRate = cashGroup.primeRate.oracleSupplyRate;
            } else {
                // Minimum value for marketIndex here is 2
                shortMaturity = referenceTime.add(DateTime.getTradedMarket(marketIndex - 1));

                shortRate = Market.getOracleRate(
                    cashGroup.currencyId,
                    shortMaturity,
                    timeWindow,
                    blockTime
                );
            }

            oracleRate = interpolateOracleRate(shortMaturity, longMaturity, shortRate, longRate, maturity);
        }
    }

    function _getCashGroupStorageBytes(uint256 currencyId) private view returns (bytes32 data) {
        mapping(uint256 => bytes32) storage store = LibStorage.getCashGroupStorage();
        return store[currencyId];
    }

    /// @dev Helper method for validating maturities in ERC1155Action
    function getMaxMarketIndex(uint256 currencyId) internal view returns (uint8) {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        return uint8(data[MARKET_INDEX_BIT]);
    }

    /// @notice Checks all cash group settings for invalid values and sets them into storage
    function setCashGroupStorage(uint256 currencyId, CashGroupSettings memory cashGroup)
        internal
    {
        // Due to the requirements of the yield curve we do not allow a cash group to have solely a 3 month market.
        // The reason is that borrowers will not have a further maturity to roll from their 3 month fixed to a 6 month
        // fixed. It also complicates the logic in the nToken initialization method. Additionally, we cannot have cash
        // groups with 0 market index, it has no effect.
        require(2 <= cashGroup.maxMarketIndex && cashGroup.maxMarketIndex <= Constants.MAX_TRADED_MARKET_INDEX);
        require(cashGroup.reserveFeeShare <= Constants.PERCENTAGE_DECIMALS);
        // Max discount factor must be set to a non-zero value
        require(0 < cashGroup.maxDiscountFactorBPS);
        require(cashGroup.minOracleRate5BPS.length == cashGroup.maxMarketIndex);
        // This is required so that fCash liquidation can proceed correctly
        require(cashGroup.liquidationfCashHaircut5BPS < cashGroup.fCashHaircut5BPS);
        require(cashGroup.liquidationDebtBuffer5BPS < cashGroup.debtBuffer5BPS);

        // Market indexes cannot decrease or they will leave fCash assets stranded in the future with no valuation curve
        uint8 previousMaxMarketIndex = getMaxMarketIndex(currencyId);
        require(previousMaxMarketIndex <= cashGroup.maxMarketIndex);

        // Per cash group settings
        bytes32 data =
            (bytes32(uint256(cashGroup.maxMarketIndex)) |
                (bytes32(uint256(cashGroup.rateOracleTimeWindow5Min)) << RATE_ORACLE_TIME_WINDOW) |
                (bytes32(uint256(cashGroup.maxDiscountFactorBPS)) << MAX_DISCOUNT_FACTOR) |
                (bytes32(uint256(cashGroup.reserveFeeShare)) << RESERVE_FEE_SHARE) |
                (bytes32(uint256(cashGroup.debtBuffer5BPS)) << DEBT_BUFFER) |
                (bytes32(uint256(cashGroup.fCashHaircut5BPS)) << FCASH_HAIRCUT) |
                (bytes32(uint256(0)) << _DEPRECATED_SETTLEMENT_PENALTY) |
                (bytes32(uint256(cashGroup.liquidationfCashHaircut5BPS)) <<
                    LIQUIDATION_FCASH_HAIRCUT) |
                (bytes32(uint256(cashGroup.liquidationDebtBuffer5BPS)) << LIQUIDATION_DEBT_BUFFER));

        // Per market group settings
        require(cashGroup.minOracleRate5BPS.length == cashGroup.maxOracleRate15BPS.length);
        for (uint256 i = 0; i < cashGroup.minOracleRate5BPS.length; i++) {
            data = data | (bytes32(uint256(cashGroup.minOracleRate5BPS[i])) << (MIN_ORACLE_RATE + i * 8));
            // Check that min is always less than max
            require(
                cashGroup.minOracleRate5BPS[i] * Constants.FIVE_BASIS_POINTS < cashGroup.maxOracleRate15BPS[i] * Constants.FIFTEEN_BASIS_POINTS
            );
        }
        for (uint256 i = 0; i < cashGroup.maxOracleRate15BPS.length; i++) {
            data = data | (bytes32(uint256(cashGroup.maxOracleRate15BPS[i])) << (MAX_ORACLE_RATE + i * 8));
        }

        mapping(uint256 => bytes32) storage store = LibStorage.getCashGroupStorage();
        store[currencyId] = data;
    }

    /// @notice Deserialize the cash group storage bytes into a user friendly object
    function deserializeCashGroupStorage(uint256 currencyId)
        internal
        view
        returns (CashGroupSettings memory)
    {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        uint8 maxMarketIndex = uint8(data[MARKET_INDEX_BIT]);
        uint8[] memory minOracleRate = new uint8[](uint256(maxMarketIndex));
        uint8[] memory maxOracleRate = new uint8[](uint256(maxMarketIndex));

        for (uint8 i = 0; i < maxMarketIndex; i++) {
            minOracleRate[i] = uint8(data[MIN_ORACLE_RATE_FIRST_BIT - i]);
            maxOracleRate[i] = uint8(data[MAX_ORACLE_RATE_FIRST_BIT - i]);
        }

        return
            CashGroupSettings({
                maxMarketIndex: maxMarketIndex,
                rateOracleTimeWindow5Min: uint8(data[RATE_ORACLE_TIME_WINDOW_BIT]),
                maxDiscountFactorBPS: uint8(data[MAX_DISCOUNT_FACTOR_BIT]),
                reserveFeeShare: uint8(data[RESERVE_FEE_SHARE_BIT]),
                debtBuffer5BPS: uint8(data[DEBT_BUFFER_BIT]),
                fCashHaircut5BPS: uint8(data[FCASH_HAIRCUT_BIT]),
                _unused: uint8(0),
                liquidationfCashHaircut5BPS: uint8(data[LIQUIDATION_FCASH_HAIRCUT_BIT]),
                liquidationDebtBuffer5BPS: uint8(data[LIQUIDATION_DEBT_BUFFER_BIT]),
                minOracleRate5BPS: minOracleRate,
                maxOracleRate15BPS: maxOracleRate
            });
    }

    function buildCashGroup(uint16 currencyId, PrimeRate memory primeRate)
        internal view returns (CashGroupParameters memory) 
    {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        uint256 maxMarketIndex = uint8(data[MARKET_INDEX_BIT]);

        return
            CashGroupParameters({
                currencyId: currencyId,
                maxMarketIndex: maxMarketIndex,
                primeRate: primeRate,
                data: data
            });
    }

    /// @notice Builds a cash group using a view version of the asset rate
    function buildCashGroupView(uint16 currencyId)
        internal
        view
        returns (CashGroupParameters memory)
    {
        (PrimeRate memory primeRate, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);
        return buildCashGroup(currencyId, primeRate);
    }

    /// @notice Builds a cash group using a stateful version of the asset rate
    function buildCashGroupStateful(uint16 currencyId)
        internal
        returns (CashGroupParameters memory)
    {
        PrimeRate memory primeRate = PrimeRateLib.buildPrimeRateStateful(currencyId);
        return buildCashGroup(currencyId, primeRate);
    }
}
