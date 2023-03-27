// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../global/Types.sol";
import "../internal/markets/CashGroup.sol";
import {PrimeRateLib} from "../internal/pCash/PrimeRateLib.sol";
import "../internal/markets/Market.sol";
import "../internal/markets/InterestRateCurve.sol";
import "../global/StorageLayoutV1.sol";
import {IPrimeCashHoldingsOracle} from "../../interfaces/notional/IPrimeCashHoldingsOracle.sol";
import "./valuation/AbstractSettingsRouter.sol";

contract MockMarket is StorageLayoutV1, AbstractSettingsRouter {
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    function getUint64(uint256 value) public pure returns (int128) {
        return ABDKMath64x64.fromUInt(value);
    }

    function buildCashGroupView(uint16 currencyId)
        public
        view
        returns (CashGroupParameters memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function calculateTrade(
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        int256 fCashAmount,
        uint256 timeToMaturity,
        uint256 marketIndex
    )
        external
        view
        returns (
            MarketParameters memory,
            int256,
            int256
        )
    {
        (int256 primeCash, int256 cashToReserve) =
            InterestRateCurve.calculatefCashTrade(marketState, cashGroup, fCashAmount, timeToMaturity, marketIndex);

        return (marketState, primeCash, cashToReserve);
    }

    function addLiquidity(MarketParameters memory marketState, int256 primeCash)
        public
        returns (
            MarketParameters memory,
            int256,
            int256
        )
    {
        (int256 liquidityTokens, int256 fCash) = marketState.addLiquidity(primeCash);
        assert(liquidityTokens >= 0);
        assert(fCash <= 0);
        return (marketState, liquidityTokens, fCash);
    }

    function removeLiquidity(MarketParameters memory marketState, int256 tokensToRemove)
        public
        returns (
            MarketParameters memory,
            int256,
            int256
        )
    {
        (int256 primeCash, int256 fCash) = marketState.removeLiquidity(tokensToRemove);

        assert(primeCash >= 0);
        assert(fCash >= 0);
        return (marketState, primeCash, fCash);
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getMarketStorageOracleRate(bytes32 slot) public view returns (uint256) {
        bytes32 data;

        assembly {
            data := sload(slot)
        }
        return uint256(uint32(uint256(data >> 192)));
    }

    function buildMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow
    ) public view returns (MarketParameters memory) {
        MarketParameters memory market;
        market.loadMarket(currencyId, maturity, blockTime, needsLiquidity, rateOracleTimeWindow);
        return market;
    }

    function getfCashAmountGivenCashAmount(
        uint16 currencyId,
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 netCashToAccount,
        uint256 marketIndex,
        uint256 timeToMaturity
    ) external view returns (int256) {
        InterestRateParameters memory irParams = InterestRateCurve.getActiveInterestRateParameters(currencyId, marketIndex);
        return InterestRateCurve.getfCashGivenCashAmount(
            irParams,
            totalfCash,
            netCashToAccount,
            totalCashUnderlying,
            timeToMaturity
        );
    }

    function getInterestRateFromUtilization(
        uint16 currencyId,
        uint8 marketIndex,
        uint256 utilization
    ) external view returns (uint256 preFeeInterestRate) {
        InterestRateParameters memory irParams = InterestRateCurve.getActiveInterestRateParameters(
            currencyId, marketIndex
        );

        return InterestRateCurve.getInterestRate(irParams, utilization);
    }
}
