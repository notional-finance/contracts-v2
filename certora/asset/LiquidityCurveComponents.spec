/**
 * The rate anchor ensures that the implied rate of the liquidity curve does not
 * change with the passage of time. If the market components (fCash and cash) do not
 * change then neither should the implied rate due to the rate anchor calculation.
 */
rule rateAnchorStabilizesImpliedRates(
    int256 totalfCash,
    int256 totalCashUnderlying,
    int256 lastImpliedRate,
    uint256 timeToMaturity,
    uint256 timeDelta
) {
    require totalfCash > 0;
    require totalCashUnderlying > 0;
    // Implied rates are bound by uint32
    require lastImpliedRate < 2^32 - 1;
    require timeToMaturity < 20 * 360 * 86400; // time to maturity is bound by 20, 360 day "years"
    require timeDelta <= 90 * 86400; // markets are open for a 90 days
    require timeToMaturity - timeDelta > 0; // markets are not open after fCash matures

    int256 rateAnchor1 = getRateAnchor(totalfCash, totalCashUnderlying, lastImpliedRate, timeToMaturity);
    uint256 impliedRate1 = getImpliedRate(totalfCash, totalCashUnderlying, rateAnchor1, timeToMaturity)

    int256 rateAnchor2 = getRateAnchor(totalfCash, totalCashUnderlying, lastImpliedRate, timeToMaturity - timeDelta);
    uint256 impliedRate2 = getImpliedRate(totalfCash, totalCashUnderlying, rateAnchor2, timeToMaturity - timeDelta)

    assert impliedRate1 == impliedRate2, "rate anchor does not stabilize implied rate";
}


/**
 * The implied interest rate of the market should increase (all other factors held constant) as the time to
 * maturity decreases. In other words, receiving 1 fCash in 1 month implies a higher interest rate than receiving
 * 1 fCash in 3 months.
 */
rule impliedRatesIncreaseTowardsMaturity(
    int256 totalfCash,
    int256 totalCashUnderlying,
    int256 rateAnchor,
    uint256 timeToMaturity,
    uint256 timeDelta
) {
    require totalfCash > 0;
    require totalCashUnderlying > 0;
    require timeToMaturity < 20 * 360 * 86400; // time to maturity is bound by 20, 360 day "years"
    require timeDelta <= 90 * 86400; // markets are open for a period of 90 days

    uint256 impliedRateShorterDuration = getImpliedRate(
        totalfCash,
        totalCashUnderlying,
        rateAnchor,
        timeToMaturity
    );

    uint256 impliedRateLongerDuration = getImpliedRate(
        totalfCash,
        totalCashUnderlying,
        rateAnchor,
        timeToMaturity + timeDelta
    );

    assert impliedRateLongerDuration <= impliedRateShorterDuration,
        "implied rate does not increase with shorter duration";
}

/**
 * Exchange rates between fCash and cash should decrease (i.e. the lender receives less interest for a given
 * cash deposit) as the size of the deposit increases. This is effect of slippage.
 */
rule exchangeRateDecreasesWithLargerLending(
    int256 totalfCash,
    int256 totalCashUnderlying,
    int256 fCashToAccount,
    int256 fCashDelta,
    int256 rateScalar,
    int256 rateAnchor
) {
    require 0 < rateScalar && rateScalar < 221184000; // max value for rate scalar is 256 * 10 * 86400 (1 second to maturity)
    require totalfCash > 0;
    require totalCashUnderlying > 0;
    require fCashToAccount > 0;
    require fCashDelta > 0;

    int256 exchangeRateLesserLend = getExchangeRate(
        totalfCash,
        totalCashUnderlying,
        rateScalar,
        rateAnchor,
        fCashToAccount
    );

    int256 exchangeRateGreaterLend = getExchangeRate(
        totalfCash,
        totalCashUnderlying,
        rateScalar,
        rateAnchor,
        fCashToAccount + fCashDelta
    );

    assert exchangeRateLesserLend >= exchangeRateGreaterLend,
        "exchange rates do not decrease with lending size";
}

/**
 * Exchange rates between fCash and cash should increase (i.e. the borrower pays more interest for a given
 * borrow size) as the size of the borrow increases. This is effect of slippage.
 */
rule exchangeRateIncreasesWithLargerBorrowing(
    int256 totalfCash,
    int256 totalCashUnderlying,
    int256 fCashToAccount,
    int256 fCashDelta,
    int256 rateScalar,
    int256 rateAnchor
) {
    require 0 < rateScalar && rateScalar < 221184000; // max value for rate scalar is 256 * 10 * 86400 (1 second to maturity)
    require totalfCash > 0;
    require totalCashUnderlying > 0;
    require fCashToAccount < 0;
    require fCashDelta < 0;

    int256 exchangeRateLesserBorrow = getExchangeRate(
        totalfCash,
        totalCashUnderlying,
        rateScalar,
        rateAnchor,
        fCashToAccount
    );

    int256 exchangeRateGreaterBorrow = getExchangeRate(
        totalfCash,
        totalCashUnderlying,
        rateScalar,
        rateAnchor,
        fCashToAccount + fCashDelta
    );

    assert exchangeRateLesserBorrow < exchangeRateGreaterBorrow,
        "exchange rates do not increase with borrow size";
}

/**
 * The rate scalar controls the range of tradable interest rates by determining the amount of slippage the
 * market will experience for a given size of trade. All other things held constant, a larger rate scalar
 * will result in less slippage in the market.
 */
rule rateScalarControlsSlippage(
    int256 totalfCash,
    int256 totalCashUnderlying,
    int256 fCashToAccount,
    int256 rateScalar1,
    int256 rateScalar2,
    int256 rateAnchor
) {
    require 0 < rateScalar1 && rateScalar1 < 221184000; // max value for rate scalar is 256 * 10 * 86400 (1 second to maturity)
    require 0 < rateScalar2 && rateScalar2 < 221184000;
    require rateScalar1 < rateScalar2;
    require totalfCash > 0;
    require totalCashUnderlying > 0;
    require fCashToAccount != 0;

    int256 exchangeRateLesserScalar = getExchangeRate(
        totalfCash,
        totalCashUnderlying,
        rateScalar1,
        rateAnchor,
        fCashToAccount
    );

    int256 exchangeRateGreaterScalar = getExchangeRate(
        totalfCash,
        totalCashUnderlying,
        rateScalar1,
        rateAnchor,
        fCashToAccount
    );

    assert fCashToAccount > 0 ?
        // When lending, a larger scalar will result in less slippage for a given lending amount
        exchangeRateLesserScalar < exchangeRateGreaterScalar :
        // When borrowing, a larger scalar will result in less slippage for a given borrowing amount
        exchangeRateLesserScalar > exchangeRateGreaterScalar,
        "larger rate scalar does not reduce slippage"
}