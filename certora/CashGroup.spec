methods {
    getMaxMarketIndex(uint256 currencyId) returns (uint8) envfree
    interpolateOracleRate(
        uint256 shortMaturity,
        uint256 longMaturity,
        uint256 shortRate,
        uint256 longRate,
        uint256 assetMaturity
    ) returns (uint256) envfree;
}

definition MIN_MARKET_INDEX() returns uint256 = 1;
definition MAX_MARKET_INDEX() returns uint256 = 7;
definition MIN_CURRENCY_ID() returns uint256 = 1;
definition MAX_CURRENCY_ID() returns uint256 = 0x3ff;
definition BASIS_POINTS() returns uint256 = 100000;

// NOTE: this cannot run without allowing calldata
rule cashGroupGetterSetters(
    uint256 currencyId,
    uint8 maxMarketIndex,
    uint8 rateOracleTimeWindowMin,
    uint8 totalFeeBPS,
    uint8 reserveFeeShare,
    uint8 debtBuffer5BPS,
    uint8 fCashHaircut5BPS,
    uint8 settlementPenaltyRate5BPS,
    uint8 liquidationfCashHaircut5BPS,
    uint8 liquidationDebtBuffer5BPS,
    uint8[] liquidityTokenHaircuts,
    uint8[] rateScalars,
    uint256 assetType
) {
    env e;
    require MIN_CURRENCY_ID() <= currencyId && currencyId <= MAX_CURRENCY_ID();
    require MIN_MARKET_INDEX() <= marketIndex && marketIndex <= MAX_MARKET_INDEX();
    require MIN_MARKET_INDEX() + 1 <= assetType && assetType <= marketIndex + 1;

    setCashGroupStorage(
        e,
        currencyId,
        maxMarketIndex,
        rateOracleTimeWindowMin,
        totalFeeBPS,
        reserveFeeShare,
        debtBuffer5BPS,
        fCashHaircut5BPS,
        settlementPenaltyRate5BPS,
        liquidationfCashHaircut5BPS,
        liquidationDebtBuffer5BPS,
        liquidityTokenHaircuts,
        rateScalars
    );

    assert maxMarketIndex == getMaxMarketIndex(currencyId), "max market index does not match";
    assert rateOracleTimeWindowMin * 60 == getRateOracleTimeWindow(currencyId), "rate oracle not returned in seconds";
    assert totalFeeBPS * BASIS_POINTS() == getTotalFee(currencyId), "total fee does not match"
    assert reserveFeeShare == getReserveFeeShare(currencyId), "reserve fee share does not match"
    assert debtBuffer5BPS * 5 * BASIS_POINTS() == getDebtBuffer(currencyId), "debt buffer does not match"
    assert fCashHaircut5BPS * 5 * BASIS_POINTS() == getfCashHaircut(currencyId), "fCash haircut does not match"
    assert settlementPenaltyRate5BPS * 5 * BASIS_POINTS() == getSettlementPenalty(currencyId), "settlement penalty does not match"
    assert liquidationfCashHaircut5BPS * 5 * BASIS_POINTS() == getLiquidationfCashHaircut(currencyId), "liquidation fcash haircut does not match"
    assert liquidationDebtBuffer5BPS * 5 * BASIS_POINTS() == getLiquidationDebtBuffer(currencyId), "liquidation debt buffer does not match"
    assert liquidityTokenHaircuts[assetType - 1] == getLiquidityHaircut(currencyId, assetType), "liquidity token haircut does not match";

    // rate scalars, todo, what do we want to test here?
}
