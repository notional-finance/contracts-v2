// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "./AssetRate.sol";
import "./DateTime.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library CashGroup {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Market for MarketParameters;

    // Offsets for the bytes of the different parameters
    uint256 private constant RATE_ORACLE_TIME_WINDOW = 8;
    uint256 private constant TOTAL_FEE = 16;
    uint256 private constant RESERVE_FEE_SHARE = 24;
    uint256 private constant DEBT_BUFFER = 32;
    uint256 private constant FCASH_HAIRCUT = 40;
    uint256 private constant SETTLEMENT_PENALTY = 48;
    uint256 private constant LIQUIDATION_FCASH_HAIRCUT = 56;
    // 9 bytes allocated per market on the liquidity token haircut
    uint256 private constant LIQUIDITY_TOKEN_HAIRCUT = 64;
    // 9 bytes allocated per market on the rate scalar
    uint256 private constant RATE_SCALAR = 136;

    /// @notice Returns the rate scalar scaled by time to maturity. The rate scalar multiplies
    /// the ln() portion of the liquidity curve as an inverse so it increases with time to
    /// maturity. The effect of the rate scalar on slippage must decrease with time to maturity.
    function getRateScalar(
        CashGroupParameters memory cashGroup,
        uint256 marketIndex,
        uint256 timeToMaturity
    ) internal pure returns (int256) {
        require(marketIndex >= 1); // dev: invalid market index
        uint256 offset = RATE_SCALAR + 8 * (marketIndex - 1);
        int256 scalar = int256(uint8(uint256(cashGroup.data >> offset))) * 10;
        int256 rateScalar =
            scalar.mul(int256(Constants.IMPLIED_RATE_TIME)).div(int256(timeToMaturity));

        require(rateScalar > 0, "CG: rate scalar underflow");
        return rateScalar;
    }

    /// @notice Haircut on liquidity tokens to account for the risk associated with changes in the
    /// proportion of cash to fCash within the pool. This is set as a percentage less than or equal to 100.
    function getLiquidityHaircut(CashGroupParameters memory cashGroup, uint256 assetType)
        internal
        pure
        returns (uint256)
    {
        require(assetType > 1); // dev: liquidity haircut invalid asset type
        uint256 offset =
            LIQUIDITY_TOKEN_HAIRCUT + 8 * (assetType - Constants.MIN_LIQUIDITY_TOKEN_INDEX);
        uint256 liquidityTokenHaircut = uint256(uint8(uint256(cashGroup.data >> offset)));
        return liquidityTokenHaircut;
    }

    /// @notice Total trading fee denominated in basis points
    function getTotalFee(CashGroupParameters memory cashGroup) internal pure returns (uint256) {
        return uint256(uint8(uint256(cashGroup.data >> TOTAL_FEE))) * Constants.BASIS_POINT;
    }

    /// @notice Percentage of the total trading fee that goes to the reserve
    function getReserveFeeShare(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (int256)
    {
        return int256(uint8(uint256(cashGroup.data >> RESERVE_FEE_SHARE)));
    }

    /// @notice fCash haircut for valuation denominated in basis points
    function getfCashHaircut(CashGroupParameters memory cashGroup) internal pure returns (uint256) {
        return
            uint256(uint8(uint256(cashGroup.data >> FCASH_HAIRCUT))) * (5 * Constants.BASIS_POINT);
    }

    /// @notice fCash debt buffer for valuation denominated in basis points
    function getDebtBuffer(CashGroupParameters memory cashGroup) internal pure returns (uint256) {
        return uint256(uint8(uint256(cashGroup.data >> DEBT_BUFFER))) * (5 * Constants.BASIS_POINT);
    }

    /// @notice Time window factor for the rate oracle denomianted in seconds
    function getRateOracleTimeWindow(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        // This is denominated in minutes in storage
        return uint256(uint8(uint256(cashGroup.data >> RATE_ORACLE_TIME_WINDOW))) * 60;
    }

    /// @notice Penalty rate for settling cash debts denominated in basis points
    function getSettlementPenalty(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        return
            uint256(uint8(uint256(cashGroup.data >> SETTLEMENT_PENALTY))) *
            (5 * Constants.BASIS_POINT);
    }

    /// @notice Haircut for fCash during liquidation denominated in basis points
    function getLiquidationfCashHaircut(CashGroupParameters memory cashGroup)
        internal
        pure
        returns (uint256)
    {
        return
            uint256(uint8(uint256(cashGroup.data >> LIQUIDATION_FCASH_HAIRCUT))) *
            (5 * Constants.BASIS_POINT);
    }

    function getMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint256 marketIndex,
        uint256 blockTime,
        bool needsLiquidity
    ) internal view returns (MarketParameters memory) {
        require(marketIndex > 0, "C: invalid market index");
        require(marketIndex <= markets.length, "C: invalid market index");
        MarketParameters memory market = markets[marketIndex - 1];

        if (market.storageSlot == 0) {
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

        if (market.totalLiquidity == 0 && needsLiquidity) {
            market.getTotalLiquidity();
        }

        return market;
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
        // we will get underflows here so we check for that
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

    function getOracleRate(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint256 assetMaturity,
        uint256 blockTime
    ) internal view returns (uint256) {
        (uint256 marketIndex, bool idiosyncractic) =
            DateTime.getMarketIndex(cashGroup.maxMarketIndex, assetMaturity, blockTime);
        MarketParameters memory market =
            getMarket(cashGroup, markets, marketIndex, blockTime, false);

        // TODO: need to review if this is the correct thing to do, we know that this will not include
        // matured assets, therefore marketIndex != 1 if we hit this point.
        if (market.oracleRate == 0) {
            // If oracleRate is zero then the market has not been initialized
            // and we want to reference the previous market for interpolating rates.
            uint256 prevBlockTime = blockTime.sub(Constants.QUARTER);
            uint256 maturity =
                DateTime.getReferenceTime(prevBlockTime).add(DateTime.getTradedMarket(marketIndex));
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
            return
                interpolateOracleRate(
                    blockTime,
                    market.maturity,
                    cashGroup.assetRate.getSupplyRate(),
                    market.oracleRate,
                    assetMaturity
                );
        }

        MarketParameters memory shortMarket =
            getMarket(cashGroup, markets, marketIndex - 1, blockTime, false);
        return
            interpolateOracleRate(
                shortMarket.maturity,
                market.maturity,
                shortMarket.oracleRate,
                market.oracleRate,
                assetMaturity
            );
    }

    function _getCashGroupStorageBytes(uint256 currencyId) private view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, "cashgroup"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return data;
    }

    /// @dev Helper method for validating maturities in ERC1155Action
    function getMaxMarketIndex(uint256 currencyId) internal view returns (uint8) {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        return uint8(data[31]);
    }

    /// @notice Checks all cash group settings for invalid values and sets them into storage
    function setCashGroupStorage(uint256 currencyId, CashGroupSettings calldata cashGroup)
        internal
    {
        bytes32 slot = keccak256(abi.encode(currencyId, "cashgroup"));
        require(
            cashGroup.maxMarketIndex >= 0 &&
                cashGroup.maxMarketIndex <= Constants.MAX_TRADED_MARKET_INDEX,
            "CG: invalid market index"
        );
        // Due to the requirements of the yield curve we do not allow a cash group to have solely a 3 month market.
        // The reason is that borrowers will not have a futher maturity to roll from their 3 month fixed to a 6 month
        // fixed. It also complicates the logic in the perpetual token initialization method
        require(cashGroup.maxMarketIndex != 1, "CG: invalid market index");
        require(
            cashGroup.reserveFeeShare <= Constants.PERCENTAGE_DECIMALS,
            "CG: invalid reserve share"
        );
        require(cashGroup.liquidityTokenHaircuts.length == cashGroup.maxMarketIndex);
        require(cashGroup.rateScalars.length == cashGroup.maxMarketIndex);
        // This is required so that fCash liquidation can proceed correctly
        require(cashGroup.liquidationfCashHaircut5BPS < cashGroup.fCashHaircut5BPS);

        // Market indexes cannot decrease or they will leave fCash assets stranded in the future with no valuation curve
        uint8 previousMaxMarketIndex = uint8(uint256(_getCashGroupStorageBytes(currencyId)));
        require(
            previousMaxMarketIndex <= cashGroup.maxMarketIndex,
            "CG: market index cannot decrease"
        );

        // Per cash group settings
        bytes32 data =
            (bytes32(uint256(cashGroup.maxMarketIndex)) |
                (bytes32(uint256(cashGroup.rateOracleTimeWindowMin)) << RATE_ORACLE_TIME_WINDOW) |
                (bytes32(uint256(cashGroup.totalFeeBPS)) << TOTAL_FEE) |
                (bytes32(uint256(cashGroup.reserveFeeShare)) << RESERVE_FEE_SHARE) |
                (bytes32(uint256(cashGroup.debtBuffer5BPS)) << DEBT_BUFFER) |
                (bytes32(uint256(cashGroup.fCashHaircut5BPS)) << FCASH_HAIRCUT) |
                (bytes32(uint256(cashGroup.settlementPenaltyRateBPS)) << SETTLEMENT_PENALTY) |
                (bytes32(uint256(cashGroup.liquidationfCashHaircut5BPS)) <<
                    LIQUIDATION_FCASH_HAIRCUT));

        // Per market group settings
        for (uint256 i; i < cashGroup.liquidityTokenHaircuts.length; i++) {
            require(
                cashGroup.liquidityTokenHaircuts[i] <= Constants.PERCENTAGE_DECIMALS,
                "CG: invalid token haircut"
            );

            data =
                data |
                (bytes32(uint256(cashGroup.liquidityTokenHaircuts[i])) <<
                    (LIQUIDITY_TOKEN_HAIRCUT + i * 8));
        }

        for (uint256 i; i < cashGroup.rateScalars.length; i++) {
            // Causes a divide by zero error
            require(cashGroup.rateScalars[i] != 0, "CG: invalid rate scalar");
            data = data | (bytes32(uint256(cashGroup.rateScalars[i])) << (RATE_SCALAR + i * 8));
        }

        assembly {
            sstore(slot, data)
        }
    }

    /// @notice Deserializes the cash group storage bytes into a user friendly object
    function deserializeCashGroupStorage(uint256 currencyId)
        internal
        view
        returns (CashGroupSettings memory)
    {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        uint8 maxMarketIndex = uint8(data[31]);
        uint8[] memory tokenHaircuts = new uint8[](uint256(maxMarketIndex));
        uint8[] memory rateScalars = new uint8[](uint256(maxMarketIndex));

        for (uint8 i; i < maxMarketIndex; i++) {
            tokenHaircuts[i] = uint8(data[23 - i]);
            rateScalars[i] = uint8(data[14 - i]);
        }

        return
            CashGroupSettings({
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

    function _buildCashGroup(uint256 currencyId, AssetRateParameters memory assetRate)
        private
        view
        returns (CashGroupParameters memory, MarketParameters[] memory)
    {
        bytes32 data = _getCashGroupStorageBytes(currencyId);
        uint256 maxMarketIndex = uint256(uint8(uint256(data)));

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

    /// @notice Builds a cash group using a view version of the asset rate
    function buildCashGroupView(uint256 currencyId)
        internal
        view
        returns (CashGroupParameters memory, MarketParameters[] memory)
    {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateView(currencyId);
        return _buildCashGroup(currencyId, assetRate);
    }

    /// @notice Builds a cash group using a stateful version of the asset rate
    function buildCashGroupStateful(uint256 currencyId)
        internal
        returns (CashGroupParameters memory, MarketParameters[] memory)
    {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(currencyId);
        return _buildCashGroup(currencyId, assetRate);
    }
}
