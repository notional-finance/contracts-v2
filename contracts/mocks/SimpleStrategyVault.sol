// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../strategyVaults/BaseStrategyVault.sol";

contract SimpleStrategyVault is BaseStrategyVault {
    bool internal _forceSettle;
    uint256 internal _tokenExchangeRate;
    function setForceSettle(bool s) external { _forceSettle = s; }
    function setExchangeRate(uint256 e) external { _tokenExchangeRate = e; }

    constructor(
        string memory name_,
        address notional_,
        uint16 borrowCurrencyId_
    ) BaseStrategyVault(name_, notional_, borrowCurrencyId_, true, true) { }

    // Vaults need to implement these two methods
    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 strategyTokensMinted) {
        strategyTokensMinted = (deposit * 1e18) / (_tokenExchangeRate * 1e10);
    }

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 assetTokensToTransfer) {
        return strategyTokens * _tokenExchangeRate * 1e10 / 1e18;
    }

    function convertStrategyToUnderlying(uint256 strategyTokens, uint256 maturity) public view override returns (uint256 underlyingValue) {
        return (strategyTokens * _tokenExchangeRate * 1e10) / 1e18;
    }
}