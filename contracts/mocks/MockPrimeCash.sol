// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/pCash/PrimeCashExchangeRate.sol";
import "../internal/pCash/PrimeRateLib.sol";
import "../internal/markets/Market.sol";
import "./valuation/AbstractSettingsRouter.sol";
import {DepositData, RedeemData} from "../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

contract MockPrimeCashOracle is IPrimeCashHoldingsOracle {
    uint256 public nativeValue;
    uint256 public internalValue;

    address[] public targets;
    bytes[] public callData;
    uint256[] public expectedUnderlying;

    function setRedeemData(
        address[] memory _targets,
        bytes[] memory _callData,
        uint256[] memory _expectedUnderlying
    ) external {
        targets = _targets;
        callData = _callData;
        expectedUnderlying = _expectedUnderlying;
    }

    function holdings() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function underlying() external pure override returns (address) {
        return address(0);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function _setValue(uint256 n, uint256 i) external {
        nativeValue = n;
        internalValue = i;
    }

    function getTotalUnderlyingValueView() external view override returns (
        uint256 nativePrecision,
        uint256 internalPrecision
    ) {
        return (nativeValue, internalValue);
    }

    function getTotalUnderlyingValueStateful() external override returns (
        uint256 nativePrecision,
        uint256 internalPrecision
    ) {
        return (nativeValue, internalValue);
    }

    function getRedemptionCalldata(uint256 withdrawAmount) external view override returns (
        RedeemData[] memory redeemData
    ) {
    }

    function holdingValuesInUnderlying() external view override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function getRedemptionCalldataForRebalancing(
        address[] calldata holdings, 
        uint256[] calldata withdrawAmounts
    ) external view override returns (
        RedeemData[] memory redeemData
    ) {
    }

    function getDepositCalldataForRebalancing(
        address[] calldata holdings, 
        uint256[] calldata depositAmount
    ) external view override returns (
        DepositData[] memory depositData
    ) {
    }
}

contract MockPrimeCash is AbstractSettingsRouter {
    using PrimeRateLib for PrimeRate;
    using Market for MarketParameters;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    /// @notice Emits every time interest is accrued
    event PrimeCashInterestAccrued(uint16 indexed currencyId);

    /// @notice Emits when the totalPrimeDebt changes due to borrowing
    event PrimeDebtChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 totalPrimeDebt
    );

    /// @notice Emits when the totalPrimeSupply changes due to token deposits or withdraws
    event PrimeSupplyChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 lastTotalUnderlyingValue
    );

    event PrimeCashCurveChanged(uint16 indexed currencyId);

    event PrimeCashHoldingsOracleUpdated(uint16 indexed currencyId, address oracle);

    event ReserveFeeAccrued(uint16 indexed currencyId, int256 fee);

    event SetPrimeSettlementRate(
        uint256 indexed currencyId,
        uint256 indexed maturity,
        int256 supplyFactor,
        int256 debtFactor
    );

    function getPrimeCashFactors(
        uint16 currencyId
    ) external view returns (PrimeCashFactors memory p) {
        return PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
    }

    function initPrimeCashCurve(
        uint16 currencyId,
        uint88 totalPrimeSupply,
        uint88 totalPrimeDebt,
        InterestRateCurveSettings calldata debtCurve,
        IPrimeCashHoldingsOracle oracle,
        bool allowPrimeCashDebt,
        uint8 rateOracleTimeWindow5Min
    ) external {
        PrimeCashExchangeRate.initTokenBalanceStorage(currencyId, oracle);

        PrimeCashExchangeRate.initPrimeCashCurve(
            currencyId, totalPrimeSupply, debtCurve, oracle, allowPrimeCashDebt, rateOracleTimeWindow5Min
        );

        PrimeCashExchangeRate.updateTotalPrimeDebt(
            address(0), currencyId, totalPrimeDebt, totalPrimeDebt
        );
    }

    function updatePrimeCashCurve(
        uint16 currencyId,
        InterestRateCurveSettings calldata debtCurve
    ) external {
        return PrimeCashExchangeRate.updatePrimeCashCurve(
            currencyId, debtCurve
        );
    }

    function updateTotalPrimeDebt(
        uint16 currencyId,
        int256 netPrimeDebtChange,
        int256 netPrimeSupplyChange
    ) external {
        // Set this here to avoid flaky test issues
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.lastAccrueTime = uint40(block.timestamp);

        return PrimeCashExchangeRate.updateTotalPrimeDebt(
            address(0), currencyId, netPrimeDebtChange, netPrimeSupplyChange
        );
    }

    function updateTotalPrimeSupply(
        uint16 currencyId,
        int256 netPrimeSupplyChange,
        int256 netUnderlyingChange
    ) external {
        // Set this here to avoid flaky test issues
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.lastAccrueTime = uint40(block.timestamp);

        return PrimeCashExchangeRate.updateTotalPrimeSupply(
            currencyId, netPrimeSupplyChange, netUnderlyingChange
        );
    }

    function getPrimeInterestRates(
        uint16 currencyId
    ) external view returns (
        uint256 annualDebtRatePreFee,
        uint256 annualDebtRatePostFee,
        uint256 annualSupplyRate
    ) {
        PrimeCashFactors memory p = PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
        return PrimeCashExchangeRate.getPrimeInterestRates(currencyId, p);
    }

    function convertToUnderlying(
        PrimeRate memory pr,
        int256 primeCashBalance
    ) external pure returns (int256) {
        return pr.convertToUnderlying(primeCashBalance);
    }

    function convertFromUnderlying(
        PrimeRate memory pr,
        int256 underlyingBalance
    ) external pure returns (int256) {
        return pr.convertFromUnderlying(underlyingBalance);
    }

    function convertDebtStorageToUnderlying(
        PrimeRate memory pr,
        int256 debtStorage
    ) external pure returns (int256) {
        return pr.convertDebtStorageToUnderlying(debtStorage);
    }

    function convertUnderlyingToDebtStorage(
        PrimeRate memory pr,
        int256 underlying
    ) external pure returns (int256) {
        return pr.convertUnderlyingToDebtStorage(underlying);
    }

    function buildPrimeRateView(
        uint16 currencyId,
        uint256 blockTime
    ) external view returns (PrimeRate memory, PrimeCashFactors memory) {
        return PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
    }

    function buildPrimeRateStateful(
        uint16 currencyId,
        uint256 blockTime
    ) external returns (PrimeRate memory) {
        return PrimeCashExchangeRate.getPrimeCashRateStateful(currencyId, blockTime);
    }

    function buildPrimeRateSettlementView(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) external view returns (PrimeRate memory pr) {
        return PrimeRateLib.buildPrimeRateSettlementView(currencyId, maturity, blockTime);
    }

    function buildPrimeRateSettlementStateful(
        uint16 currencyId,
        uint256 maturity
    ) external returns (PrimeRate memory pr) {
        return PrimeRateLib.buildPrimeRateSettlementStateful(currencyId, maturity, block.timestamp);
    }

    function negChange(int256 start, int256 end) external pure returns (int256) {
        return SafeInt256.negChange(start, end);
    }

    function convertFromStorage(
        PrimeRate memory pr,
        int256 storedCashBalance
    ) external view returns (int256) {
        return pr.convertFromStorage(storedCashBalance);
    }

    function convertToStorageValue(
        PrimeRate memory pr,
        int256 signedPrimeSupplyValueToStore
    ) external view returns (int256 newStoredCashBalance) {
        return pr.convertToStorageValue(signedPrimeSupplyValueToStore);
    }

    function convertToStorageInSettlement(
        uint16 currencyId,
        int256 previousStoredCashBalance,
        int256 positiveSettledCash,
        int256 negativeSettledCash
    ) external returns (int256 newStoredCashBalance) {
        PrimeRate memory pr = PrimeRateLib.buildPrimeRateStateful(currencyId);

        return pr.convertToStorageInSettlement(
            address(0), currencyId, previousStoredCashBalance, positiveSettledCash, negativeSettledCash
        );
    }

    function convertToStorageNonSettlement(
        PrimeRate memory pr,
        uint16 currencyId,
        int256 previousStoredCashBalance,
        int256 signedPrimeSupplyValueToStore,
        uint40 blockTime
    ) external returns (int256 newStoredCashBalance) {
        // Set this here to avoid flaky test issues
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.lastAccrueTime = blockTime == 0 ? uint40(block.timestamp) : blockTime;

        return pr.convertToStorageNonSettlementNonVault(
            address(0), currencyId, previousStoredCashBalance, signedPrimeSupplyValueToStore
        );
    }

    function convertSettledfCash(
        PrimeRate memory presentPrimeRate,
        uint16 currencyId,
        uint256 maturity,
        int256 fCashBalance,
        uint256 blockTime
    ) external returns (int256) {
        return presentPrimeRate.convertSettledfCash(
            address(0),
            currencyId,
            maturity,
            fCashBalance,
            blockTime
        );
    }

    function setMarket(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) external {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) external view returns (MarketParameters memory s) {
        Market.loadSettlementMarket(s, currencyId, maturity, settlementDate);
    }

    function updateTotalfCashDebtOutstanding(
        uint16 currencyId,
        uint256 maturity,
        int256 netDebtChange
    ) external {
        PrimeCashExchangeRate.updateTotalfCashDebtOutstanding(
            msg.sender, currencyId, maturity, 0, -netDebtChange
        );
    }

    function getTotalfCashDebtOutstanding(
        uint16 currencyId,
        uint256 maturity
    ) external view returns (int256) {
        return PrimeCashExchangeRate.getTotalfCashDebtOutstanding(
            currencyId,
            maturity
        );
    }
}
