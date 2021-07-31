contract SettlementHarness {
    function getSettlementRate(uint256 currencyId, uint256 maturity)
        external
        view
        returns (int256)
    {}

    function getCashBalance(uint256 currencyId) external view returns (int256) {}

    function getNumSettleableAssets(address account) external view returns (uint256) {}

    function getAmountToSettle(uint256 currencyId, address account)
        external
        view
        returns (int256)
    {}

    function getNumAssets(address account) external view returns (uint256) {}

    function settleAccount(address account) external {}
}
