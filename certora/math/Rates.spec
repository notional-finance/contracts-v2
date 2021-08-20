methods {
    getMinRate(uint8 decimals) returns (int256) envfree;
    isGTE(int256 x, int256 y) returns (bool) envfree;
    isLT(int256 x, int256 y) returns (bool) envfree;
    convertToUnderlying(int256 rate, int256 balance, uint8 decimals) returns (int256) envfree;
    convertFromUnderlying(int256 rate, int256 balance, uint8 decimals) returns (int256) envfree;

    convertToETH(
        int256 rate,
        int256 balance,
        uint8 decimals,
        int256 buffer,
        int256 haircut
    ) returns (int256) envfree;

    convertETHTo(
        int256 rate,
        int256 balance,
        uint8 decimals,
        int256 buffer,
        int256 haircut
    ) returns (int256) envfree;
}

// FAIL: don't understand
// https://vaas-stg.certora.com/output/42394/b653a6ce616e543b6fc2/?anonymousKey=99c89d5a9b9b2e750db48f6227d9681876371d81
rule assetRatesShouldBeInverses(int256 rate, int256 balance, uint8 decimals) {
    require 0 <= decimals && decimals <= 18;
    // Asset Rates should bottom out at 1-1.
    // TODO: why is min rate returning zero?
    int256 minRate = getMinRate(decimals);
    require isGTE(rate, minRate);

    int256 underlying = convertToUnderlying(rate, balance, decimals);
    int256 asset = convertFromUnderlying(rate, underlying, decimals);

    assert asset == balance;
}

// TIMEOUT: https://vaas-stg.certora.com/output/42394/da7a099706b1993b06db/?anonymousKey=b501b0398a52bade683149b4c4244ac69fdaf5e9
rule exchangeRateShouldBeInverses(int256 rate, int256 balance, uint8 rateDecimals) {
    require 0 < rateDecimals && rateDecimals <= 18;
    // TODO: need to ensure that this does not zero out exchange rates
    require rate > 0;

    int256 eth = convertToETH(rate, balance, rateDecimals, 100, 100);
    require eth != 0;
    int256 original = convertETHTo(rate, eth, rateDecimals, 100, 100);
    int256 balancePlus1 = balance + 1;
    int256 balanceMinus1 = balance - 1;

    assert original == balance || original == balancePlus1 || original == balanceMinus1;
}

// Failure: don't understand:
// https://vaas-stg.certora.com/output/42394/a603ae8e06194f6c3426/?anonymousKey=2379c9882300e5d06cd3ea682caf9972d4307a54
rule exchangeRateHaircutBuffer(int256 rate, int256 balance, uint8 decimals, int256 haircut, int256 buffer) {
    require 0 < decimals && decimals <= 18;
    require rate > 0;
    // Do not allow 100 as haircut or buffer for assertions
    require 0 <= haircut && haircut < 100;
    require 100 < buffer && buffer <= 256;

    int256 ethWithHaircutBuffer = convertToETH(rate, balance, decimals, haircut, buffer);
    int256 ethNoHaircutBuffer = convertToETH(rate, balance, decimals, 100, 100);

    assert balance > 0 => ethWithHaircutBuffer >= 0 && ethNoHaircutBuffer >= 0;
    assert balance < 0 => ethWithHaircutBuffer <= 0 && ethNoHaircutBuffer <= 0;
    assert ethNoHaircutBuffer == 0 => ethWithHaircutBuffer == 0;
    assert ethNoHaircutBuffer != 0 => isLT(ethWithHaircutBuffer, ethNoHaircutBuffer);
}