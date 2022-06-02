// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../strategyVaults/BaseStrategyVault.sol";

contract SimpleStrategyVault is BaseStrategyVault {
    bool internal _inSettlement;
    bool internal _forceSettle;
    uint256 internal _tokenExchangeRate;
    function setForceSettle(bool s) external { _forceSettle = s; }
    function setSettlement(bool s) external { _inSettlement = s; }
    function setExchangeRate(uint256 e) external { _tokenExchangeRate = e; }

    constructor(
        string memory name_,
        string memory symbol_,
        address notional_,
        uint16 borrowCurrencyId_
    ) BaseStrategyVault(name_, symbol_, notional_, borrowCurrencyId_, true, true) { }

    // Vaults need to implement these two methods
    function _depositFromNotional(
        uint256 deposit,
        bytes calldata data
    ) internal override returns (uint256 strategyTokensMinted) {
        strategyTokensMinted = (deposit * 1e18) / (_tokenExchangeRate * 1e10);
        _mint(address(NOTIONAL), strategyTokensMinted);
    }

    function _redeemFromNotional(
        uint256 strategyTokens,
        bytes calldata data
    ) internal override returns (uint256 assetTokensToTransfer) {
        _burn(address(NOTIONAL), strategyTokens);
        return strategyTokens * _tokenExchangeRate * 1e10 / 1e18;
    }

    function canSettleMaturity(uint256 maturity) external view override returns (bool) {
        if (_forceSettle) return true;

        (int256 assetCashToSettle, /* */) = NOTIONAL.getCashRequiredToSettle(address(this), maturity);
        return assetCashToSettle <= 0 || totalSupply() == 0;
    }

    function convertStrategyToUnderlying(uint256 strategyTokens) public view override returns (uint256 underlyingValue) {
        return (strategyTokens * _tokenExchangeRate * 1e10) / 1e18;
    }

    function isInSettlement() external view override returns (bool) { return _inSettlement; }
}