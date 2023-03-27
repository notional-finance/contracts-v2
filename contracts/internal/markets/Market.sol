// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    MarketStorage,
    MarketParameters,
    CashGroupParameters
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {Emitter} from "../Emitter.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";
import {DateTime} from "./DateTime.sol";
import {InterestRateCurve} from "./InterestRateCurve.sol";

library Market {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;

    /// @notice Add liquidity to a market, assuming that it is initialized. If not then
    /// this method will revert and the market must be initialized first.
    /// Return liquidityTokens and negative fCash to the portfolio
    function addLiquidity(MarketParameters memory market, int256 primeCash)
        internal
        returns (int256 liquidityTokens, int256 fCash)
    {
        require(market.totalLiquidity > 0, "M: zero liquidity");
        if (primeCash == 0) return (0, 0);
        require(primeCash > 0); // dev: negative asset cash

        liquidityTokens = market.totalLiquidity.mul(primeCash).div(market.totalPrimeCash);
        // No need to convert this to underlying, primeCash / totalPrimeCash is a unitless proportion.
        fCash = market.totalfCash.mul(primeCash).div(market.totalPrimeCash);

        market.totalLiquidity = market.totalLiquidity.add(liquidityTokens);
        market.totalfCash = market.totalfCash.add(fCash);
        market.totalPrimeCash = market.totalPrimeCash.add(primeCash);
        _setMarketStorageForLiquidity(market);
        // Flip the sign to represent the LP's net position
        fCash = fCash.neg();
    }

    /// @notice Remove liquidity from a market, assuming that it is initialized.
    /// Return primeCash and positive fCash to the portfolio
    function removeLiquidity(MarketParameters memory market, int256 tokensToRemove)
        internal
        returns (int256 primeCash, int256 fCash)
    {
        if (tokensToRemove == 0) return (0, 0);
        require(tokensToRemove > 0); // dev: negative tokens to remove

        primeCash = market.totalPrimeCash.mul(tokensToRemove).div(market.totalLiquidity);
        fCash = market.totalfCash.mul(tokensToRemove).div(market.totalLiquidity);

        market.totalLiquidity = market.totalLiquidity.subNoNeg(tokensToRemove);
        market.totalfCash = market.totalfCash.subNoNeg(fCash);
        market.totalPrimeCash = market.totalPrimeCash.subNoNeg(primeCash);

        _setMarketStorageForLiquidity(market);
    }

    function executeTrade(
        MarketParameters memory market,
        address account,
        CashGroupParameters memory cashGroup,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        uint256 marketIndex
    ) internal returns (int256 netPrimeCash) {
        int256 netPrimeCashToReserve;
        (netPrimeCash, netPrimeCashToReserve) = InterestRateCurve.calculatefCashTrade(
            market,
            cashGroup,
            fCashToAccount,
            timeToMaturity,
            marketIndex
        );

        MarketStorage storage marketStorage = _getMarketStoragePointer(market);
        _setMarketStorage(
            marketStorage,
            market.totalfCash,
            market.totalPrimeCash,
            market.lastImpliedRate,
            market.oracleRate,
            market.previousTradeTime
        );
        BalanceHandler.incrementFeeToReserve(cashGroup.currencyId, netPrimeCashToReserve);

        Emitter.emitfCashMarketTrade(
            account, cashGroup.currencyId, market.maturity, fCashToAccount, netPrimeCash, netPrimeCashToReserve
        );
    }

    function getOracleRate(
        uint256 currencyId,
        uint256 maturity,
        uint256 rateOracleTimeWindow,
        uint256 blockTime
    ) internal view returns (uint256) {
        mapping(uint256 => mapping(uint256 => 
            mapping(uint256 => MarketStorage))) storage store = LibStorage.getMarketStorage();
        uint256 settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        MarketStorage storage marketStorage = store[currencyId][maturity][settlementDate];

        uint256 lastImpliedRate = marketStorage.lastImpliedRate;
        uint256 oracleRate = marketStorage.oracleRate;
        uint256 previousTradeTime = marketStorage.previousTradeTime;

        // If the oracle rate is set to zero this can only be because the markets have past their settlement
        // date but the new set of markets has not yet been initialized. This means that accounts cannot be liquidated
        // during this time, but market initialization can be called by anyone so the actual time that this condition
        // exists for should be quite short.
        require(oracleRate > 0, "Market not initialized");

        return
            InterestRateCurve.updateRateOracle(
                previousTradeTime,
                lastImpliedRate,
                oracleRate,
                rateOracleTimeWindow,
                blockTime
            );
    }

    /// @notice Reads a market object directly from storage. `loadMarket` should be called instead of this method
    /// which ensures that the rate oracle is set properly.
    function _loadMarketStorage(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        bool needsLiquidity,
        uint256 settlementDate
    ) private view {
        // Market object always uses the most current reference time as the settlement date
        mapping(uint256 => mapping(uint256 => 
            mapping(uint256 => MarketStorage))) storage store = LibStorage.getMarketStorage();
        MarketStorage storage marketStorage = store[currencyId][maturity][settlementDate];
        bytes32 slot;
        assembly {
            slot := marketStorage.slot
        }

        market.storageSlot = slot;
        market.maturity = maturity;
        market.totalfCash = marketStorage.totalfCash;
        market.totalPrimeCash = marketStorage.totalPrimeCash;
        market.lastImpliedRate = marketStorage.lastImpliedRate;
        market.oracleRate = marketStorage.oracleRate;
        market.previousTradeTime = marketStorage.previousTradeTime;

        if (needsLiquidity) {
            market.totalLiquidity = marketStorage.totalLiquidity;
        } else {
            market.totalLiquidity = 0;
        }
    }

    function _getMarketStoragePointer(
        MarketParameters memory market
    ) private pure returns (MarketStorage storage marketStorage) {
        bytes32 slot = market.storageSlot;
        assembly {
            marketStorage.slot := slot
        }
    }

    function _setMarketStorageForLiquidity(MarketParameters memory market) internal {
        MarketStorage storage marketStorage = _getMarketStoragePointer(market);
        // Oracle rate does not change on liquidity
        uint32 storedOracleRate = marketStorage.oracleRate;

        _setMarketStorage(
            marketStorage,
            market.totalfCash,
            market.totalPrimeCash,
            market.lastImpliedRate,
            storedOracleRate,
            market.previousTradeTime
        );

        _setTotalLiquidity(marketStorage, market.totalLiquidity);
    }

    function setMarketStorageForInitialize(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 settlementDate
    ) internal {
        // On initialization we have not yet calculated the storage slot so we get it here.
        mapping(uint256 => mapping(uint256 => 
            mapping(uint256 => MarketStorage))) storage store = LibStorage.getMarketStorage();
        MarketStorage storage marketStorage = store[currencyId][market.maturity][settlementDate];

        _setMarketStorage(
            marketStorage,
            market.totalfCash,
            market.totalPrimeCash,
            market.lastImpliedRate,
            market.oracleRate,
            market.previousTradeTime
        );

        _setTotalLiquidity(marketStorage, market.totalLiquidity);
    }

    function _setTotalLiquidity(
        MarketStorage storage marketStorage,
        int256 totalLiquidity
    ) internal {
        require(totalLiquidity >= 0 && totalLiquidity <= type(uint80).max); // dev: market storage totalLiquidity overflow
        marketStorage.totalLiquidity = uint80(totalLiquidity);
    }

    function _setMarketStorage(
        MarketStorage storage marketStorage,
        int256 totalfCash,
        int256 totalPrimeCash,
        uint256 lastImpliedRate,
        uint256 oracleRate,
        uint256 previousTradeTime
    ) private {
        require(totalfCash >= 0 && totalfCash <= type(uint80).max); // dev: storage totalfCash overflow
        require(totalPrimeCash >= 0 && totalPrimeCash <= type(uint80).max); // dev: storage totalPrimeCash overflow
        require(0 < lastImpliedRate && lastImpliedRate <= type(uint32).max); // dev: storage lastImpliedRate overflow
        require(0 < oracleRate && oracleRate <= type(uint32).max); // dev: storage oracleRate overflow
        require(0 <= previousTradeTime && previousTradeTime <= type(uint32).max); // dev: storage previous trade time overflow

        marketStorage.totalfCash = uint80(totalfCash);
        marketStorage.totalPrimeCash = uint80(totalPrimeCash);
        marketStorage.lastImpliedRate = uint32(lastImpliedRate);
        marketStorage.oracleRate = uint32(oracleRate);
        marketStorage.previousTradeTime = uint32(previousTradeTime);
    }

    /// @notice Creates a market object and ensures that the rate oracle time window is updated appropriately.
    function loadMarket(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow
    ) internal view {
        // Always reference the current settlement date
        uint256 settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        loadMarketWithSettlementDate(
            market,
            currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            rateOracleTimeWindow,
            settlementDate
        );
    }

    /// @notice Creates a market object and ensures that the rate oracle time window is updated appropriately, this
    /// is mainly used in the InitializeMarketAction contract.
    function loadMarketWithSettlementDate(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow,
        uint256 settlementDate
    ) internal view {
        _loadMarketStorage(market, currencyId, maturity, needsLiquidity, settlementDate);

        market.oracleRate = InterestRateCurve.updateRateOracle(
            market.previousTradeTime,
            market.lastImpliedRate,
            market.oracleRate,
            rateOracleTimeWindow,
            blockTime
        );
    }

    function loadSettlementMarket(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) internal view {
        _loadMarketStorage(market, currencyId, maturity, true, settlementDate);
    }

}
