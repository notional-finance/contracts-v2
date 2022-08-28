// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./Market.sol";
import "./AssetRate.sol";
import "./DateTime.sol";
import "../../global/LibStorage.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library CashGroup {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Market for MarketParameters;

    // Bit number references for each parameter in the 32 byte word (0-indexed)
    uint256 private constant MARKET_INDEX_BIT = 31;
    uint256 private constant RATE_ORACLE_TIME_WINDOW_BIT = 30;
    uint256 private constant TOTAL_FEE_BIT = 29;
    uint256 private constant RESERVE_FEE_SHARE_BIT = 28;
    uint256 private constant DEBT_BUFFER_BIT = 27;
    uint256 private constant FCASH_HAIRCUT_BIT = 26;
    uint256 private constant SETTLEMENT_PENALTY_BIT = 25;
    uint256 private constant LIQUIDATION_FCASH_HAIRCUT_BIT = 24;
    uint256 private constant LIQUIDATION_DEBT_BUFFER_BIT = 23;
    // 7 bytes allocated, one byte per market for the liquidity token haircut
    uint256 private constant LIQUIDITY_TOKEN_HAIRCUT_FIRST_BIT = 22;
    // 7 bytes allocated, one byte per market for the rate scalar
    uint256 private constant RATE_SCALAR_FIRST_BIT = 15;

    // Offsets for the bytes of the different parameters
    uint256 private constant MARKET_INDEX = (31 - MARKET_INDEX_BIT) * 8;
    uint256 private constant RATE_ORACLE_TIME_WINDOW = (31 - RATE_ORACLE_TIME_WINDOW_BIT) * 8;
    uint256 private constant TOTAL_FEE = (31 - TOTAL_FEE_BIT) * 8;
    uint256 private constant RESERVE_FEE_SHARE = (31 - RESERVE_FEE_SHARE_BIT) * 8;
    uint256 private constant DEBT_BUFFER = (31 - DEBT_BUFFER_BIT) * 8;
    uint256 private constant FCASH_HAIRCUT = (31 - FCASH_HAIRCUT_BIT) * 8;
    uint256 private constant SETTLEMENT_PENALTY = (31 - SETTLEMENT_PENALTY_BIT) * 8;
    uint256 private constant LIQUIDATION_FCASH_HAIRCUT = (31 - LIQUIDATION_FCASH_HAIRCUT_BIT) * 8;
    uint256 private constant LIQUIDATION_DEBT_BUFFER = (31 - LIQUIDATION_DEBT_BUFFER_BIT) * 8;
    uint256 private constant LIQUIDITY_TOKEN_HAIRCUT = (31 - LIQUIDITY_TOKEN_HAIRCUT_FIRST_BIT) * 8;
    uint256 private constant RATE_SCALAR = (31 - RATE_SCALAR_FIRST_BIT) * 8;

    /// @notice Returns the rate scalar scaled by time to maturity. The rate scalar multiplies
    /// the ln() portion of the liquidity curve as an inverse so it increases with time to
    /// maturity. The effect of the rate scalar on slippage must decrease with time to maturity.
    function getRateScalar(
        CashGroupParameters memory cashGroup,
        uint256 marketIndex,
        uint256 timeToMaturity
    ) internal pure returns (int256) {
        require(1 <= marketIndex && marketIndex <= cashGroup.maxMarketIndex); // dev: invalid market index

        uint256 offset = RATE_SCALAR + 8 * (marketIndex - 1);
        int256 scalar = int256(uint8(uint256(cashGroup.data >> offset))) * Constants.RATE_PRECISION;
        int256 rateScalar =
            scalar.mul(int256(Constants.IMPLIED_RATE_TIME)).div(SafeInt256.toInt(timeToMaturity));

        // Rate scalar is denominated in RATE_PRECISION, it is unlikely to underflow in the
        // division above.
        require(rateScalar > 0); // dev: rate scalar underflow
        return rateScalar;
    }

    /// @notice Haircut on liquidity tokens to account for the risk associated with changes in the
    /// proportion of cash to fCash within the pool. This is set as a percentage less than or equal to 100.
    function getLiquidityHaircut(CashGroupParameters memory cashGroup, uint256 assetType)
        internal
        pure
        returns (uint8)
    {
        require(
            Constants.MIN_LIQUIDITY_TOKEN_INDEX <= assetType &&
            assetType <= Constants.MAX_LIQUIDITY_TOKEN_INDEX
        ); // dev: liquidity haircut invalid asset type
        uint256 offset =
            LIQUIDITY_TOKEN_HAIRCUT + 8 * (assetType - Constants.MIN_LIQUIDITY_TOKEN_INDEX);
        return uint8(uint256(cashGroup.data >> offset));
    }

    /// @notice Total trading fee denominated in RATE_PRECISION with basis point increments
    function getTotalFee(CashGroupParameters memory cashGroup) internal pure returns (uint256) {
        return uint256(uint8(uint256(cashGroup.data >> TOTAL_FEE))) * Constants.BASIS_POINT;
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

    /// @notice Penalty rate for settling cash debts denominated in basis points
    function getSettlementPenalty(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        return
            uint256(uint8(uint256(cashGroup.data >> SETTLEMENT_PENALTY))) * Constants.FIVE_BASIS_POINTS;
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

    /// @dev Gets an oracle rate given any valid maturity.
    function calculateOracleRate(
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 blockTime
    ) internal view returns (uint256) {
        (uint256 marketIndex, bool idiosyncratic) =
            DateTime.getMarketIndex(cashGroup.maxMarketIndex, maturity, blockTime);
        uint256 timeWindow = getRateOracleTimeWindow(cashGroup);

        if (!idiosyncratic) {
            return Market.getOracleRate(cashGroup.currencyId, maturity, timeWindow, blockTime);
        } else {
            uint256 referenceTime = DateTime.getReferenceTime(blockTime);
            // DateTime.getMarketIndex returns the market that is past the maturity if idiosyncratic
            uint256 longMaturity = referenceTime.add(DateTime.getTradedMarket(marketIndex));
            uint256 longRate =
                Market.getOracleRate(cashGroup.currencyId, longMaturity, timeWindow, blockTime);

            uint256 shortMaturity;
            uint256 shortRate;
            if (marketIndex == 1) {
                // In this case the short market is the annualized asset supply rate
                shortMaturity = blockTime;
                shortRate = cashGroup.assetRate.getSupplyRate();
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

            return interpolateOracleRate(shortMaturity, longMaturity, shortRate, longRate, maturity);
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
    function setCashGroupStorage(uint256 currencyId, CashGroupSettings calldata cashGroup)
        internal
    {
        // Due to the requirements of the yield curve we do not allow a cash group to have solely a 3 month market.
        // The reason is that borrowers will not have a further maturity to roll from their 3 month fixed to a 6 month
        // fixed. It also complicates the logic in the nToken initialization method. Additionally, we cannot have cash
        // groups with 0 market index, it has no effect.
        require(2 <= cashGroup.maxMarketIndex && cashGroup.maxMarketIndex <= Constants.MAX_TRADED_MARKET_INDEX,
            "CG: invalid market index"
        );
        require(
            cashGroup.reserveFeeShare <= Constants.PERCENTAGE_DECIMALS,
            "CG: invalid reserve share"
        );
        require(cashGroup.liquidityTokenHaircuts.length == cashGroup.maxMarketIndex);
        require(cashGroup.rateScalars.length == cashGroup.maxMarketIndex);
        // This is required so that fCash liquidation can proceed correctly
        require(cashGroup.liquidationfCashHaircut5BPS < cashGroup.fCashHaircut5BPS);
        require(cashGroup.liquidationDebtBuffer5BPS < cashGroup.debtBuffer5BPS);

        // Market indexes cannot decrease or they will leave fCash assets stranded in the future with no valuation curve
        uint8 previousMaxMarketIndex = getMaxMarketIndex(currencyId);
        require(
            previousMaxMarketIndex <= cashGroup.maxMarketIndex,
            "CG: market index cannot decrease"
        );

        // Per cash group settings
        bytes32 data =
            (bytes32(uint256(cashGroup.maxMarketIndex)) |
                (bytes32(uint256(cashGroup.rateOracleTimeWindow5Min)) << RATE_ORACLE_TIME_WINDOW) |
                (bytes32(uint256(cashGroup.totalFeeBPS)) << TOTAL_FEE) |
                (bytes32(uint256(cashGroup.reserveFeeShare)) << RESERVE_FEE_SHARE) |
                (bytes32(uint256(cashGroup.debtBuffer5BPS)) << DEBT_BUFFER) |
                (bytes32(uint256(cashGroup.fCashHaircut5BPS)) << FCASH_HAIRCUT) |
                (bytes32(uint256(cashGroup.settlementPenaltyRate5BPS)) << SETTLEMENT_PENALTY) |
                (bytes32(uint256(cashGroup.liquidationfCashHaircut5BPS)) <<
                    LIQUIDATION_FCASH_HAIRCUT) |
                (bytes32(uint256(cashGroup.liquidationDebtBuffer5BPS)) << LIQUIDATION_DEBT_BUFFER));

        // Per market group settings
        for (uint256 i = 0; i < cashGroup.liquidityTokenHaircuts.length; i++) {
            require(
                cashGroup.liquidityTokenHaircuts[i] <= Constants.PERCENTAGE_DECIMALS,
                "CG: invalid token haircut"
            );

            data =
                data |
                (bytes32(uint256(cashGroup.liquidityTokenHaircuts[i])) <<
                    (LIQUIDITY_TOKEN_HAIRCUT + i * 8));
        }

        for (uint256 i = 0; i < cashGroup.rateScalars.length; i++) {
            // Causes a divide by zero error
            require(cashGroup.rateScalars[i] != 0, "CG: invalid rate scalar");
            data = data | (bytes32(uint256(cashGroup.rateScalars[i])) << (RATE_SCALAR + i * 8));
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
        uint8[] memory tokenHaircuts = new uint8[](uint256(maxMarketIndex));
        uint8[] memory rateScalars = new uint8[](uint256(maxMarketIndex));

        for (uint8 i = 0; i < maxMarketIndex; i++) {
            tokenHaircuts[i] = uint8(data[LIQUIDITY_TOKEN_HAIRCUT_FIRST_BIT - i]);
            rateScalars[i] = uint8(data[RATE_SCALAR_FIRST_BIT - i]);
        }

        return
            CashGroupSettings({
                maxMarketIndex: maxMarketIndex,
                rateOracleTimeWindow5Min: uint8(data[RATE_ORACLE_TIME_WINDOW_BIT]),
                totalFeeBPS: uint8(data[TOTAL_FEE_BIT]),
                reserveFeeShare: uint8(data[RESERVE_FEE_SHARE_BIT]),
                debtBuffer5BPS: uint8(data[DEBT_BUFFER_BIT]),
                fCashHaircut5BPS: uint8(data[FCASH_HAIRCUT_BIT]),
                settlementPenaltyRate5BPS: uint8(data[SETTLEMENT_PENALTY_BIT]),
                liquidationfCashHaircut5BPS: uint8(data[LIQUIDATION_FCASH_HAIRCUT_BIT]),
                liquidationDebtBuffer5BPS: uint8(data[LIQUIDATION_DEBT_BUFFER_BIT]),
                liquidityTokenHaircuts: tokenHaircuts,
                rateScalars: rateScalars
            });
    }

    function _buildCashGroup(uint16 currencyId, AssetRateParameters memory assetRate)
        private
        view
        returns (CashGroupParameters memory)
    {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        uint256 maxMarketIndex = uint8(data[MARKET_INDEX_BIT]);

        return
            CashGroupParameters({
                currencyId: currencyId,
                maxMarketIndex: maxMarketIndex,
                assetRate: assetRate,
                data: data
            });
    }

    /// @notice Builds a cash group using a view version of the asset rate
    function buildCashGroupView(uint16 currencyId)
        internal
        view
        returns (CashGroupParameters memory)
    {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateView(currencyId);
        return _buildCashGroup(currencyId, assetRate);
    }

    /// @notice Builds a cash group using a stateful version of the asset rate
    function buildCashGroupStateful(uint16 currencyId)
        internal
        returns (CashGroupParameters memory)
    {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(currencyId);
        return _buildCashGroup(currencyId, assetRate);
    }
}
