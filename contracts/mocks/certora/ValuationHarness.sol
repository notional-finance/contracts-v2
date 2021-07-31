contract ValuationHarness {
    function getMaturityAtMarketIndex(uint256 marketIndex, uint256 blockTime)
        external
        pure
        returns (uint256)
    {}

    function calculateOracleRate(uint256 currencyId, uint256 maturity)
        external
        view
        returns (uint256)
    {}

    function getPresentValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) external view returns (int256) {}

    function getRiskAdjustedPresentValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) external view returns (int256) {}

    function getLiquidityTokenValue(
        int256 fCashNotional,
        uint256 tokens,
        uint256 totalfCash,
        uint256 totalAssetCash,
        uint256 totalLiquidity,
        uint8 tokenHaircut,
        uint256 oracleRate,
        bool riskAdjusted
    ) external view returns (int256, int256) {}

    function checkPortfolioSorted(address account) external view returns (bool) {}

    function getPortfolioCurrencyIdAtIndex(address account, uint256 index)
        external
        view
        returns (uint256)
    {}

    function getNetCashGroupValue(address account, uint256 index)
        external
        view
        returns (int256, uint256)
    {}

    function getifCashNetPresentValue(address account) external view returns (int256) {}

    function getNumBitmapAssets(address account) external view returns (uint256) {}
}
