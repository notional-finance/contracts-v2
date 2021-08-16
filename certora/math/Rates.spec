methods {
    getDecimals(uint8 decimals) returns (int256) envfree;
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

rule assetRatesShouldBeInverses(int256 rate, int256 balance, uint8 decimals) {
    require 0 <= decimals && decimals <= 18;
    // Asset Rates should bottom out at 1-1.
    int256 minRate = ((10 ^ 10) * getDecimals(decimals));
    // TODO: this comparison does not work
    require rate > minRate;

    int256 underlying = convertToUnderlying(rate, balance, decimals);
    int256 asset = convertFromUnderlying(rate, underlying, decimals);

    assert asset == balance;
}

rule exchangeRateShouldBeInverses(int256 rate, int256 balance, uint8 decimals) {
    require 0 < decimals && decimals <= 18;
    // TODO: need to ensure that this does not zero out exchange rates
    require rate > 0;

    int256 eth = convertToETH(rate, balance, decimals, 100, 100);
    require eth != 0;
    int256 original = convertETHTo(rate, eth, decimals, 100, 100);

    assert original == balance;
}

rule exchangeRateHaircutBuffer(int256 rate, int256 balance, uint8 decimals, int256 haircut, int256 buffer) {
    require 0 < decimals && decimals <= 18;
    require rate > 0;
    // Do not allow 100 as haircut or buffer for assertions
    require 0 <= haircut && haircut < 100;
    require 100 < buffer && buffer <= 256;

    int256 ethWithHaircutBuffer = convertToETH(rate, balance, decimals, haircut, buffer);
    int256 ethNoHaircutBuffer = convertToETH(rate, balance, decimals, 100, 100);

    assert (ethNoHaircutBuffer == 0 && ethWithHaircutBuffer == 0) || ethWithHaircutBuffer < ethNoHaircutBuffer;
}