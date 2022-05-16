// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../strategyVaults/BaseStrategyVault.sol";

contract SimpleStrategyVault is BaseStrategyVault {
    bool internal _inSettlement;
    uint256 internal _tokenExchangeRate;
    function setSettlement(bool s) external { _inSettlement = s; }
    function setExchangeRate(uint256 e) external { _tokenExchangeRate = e; }

    constructor(
        string memory name_,
        string memory symbol_,
        address notional_,
        uint16 borrowCurrencyId_
    ) BaseStrategyVault(name_, symbol_, notional_, borrowCurrencyId_, true) { }

    // Vaults need to implement these two methods
    function _depositFromNotional(
        uint256 deposit,
        bytes calldata data
    ) internal override returns (uint256 strategyTokensMinted) {
        // TODO: convert deposit from asset cash denomination first, perhaps
        strategyTokensMinted = (deposit * _tokenExchangeRate / 1e18 / 1e10);
        _mint(address(NOTIONAL), strategyTokensMinted);
    }

    function _redeemFromNotional(
        uint256 strategyTokens,
        bytes calldata data
    ) internal override returns (uint256 assetTokensToTransfer) {
        _burn(address(NOTIONAL), strategyTokens);
        // TODO: convert deposit from asset cash denomination first, perhaps
        return (strategyTokens * 1e10 * 1e18) / _tokenExchangeRate;
    }

    function canSettleMaturity(uint256 maturity) external view override returns (bool) {
        return false;
    }

    function convertStrategyToUnderlying(uint256 strategyTokens) public view override returns (uint256 underlyingValue) {
        return (strategyTokens * _tokenExchangeRate) / 1e18;
    }

    function isInSettlement() external view override returns (bool) { return _inSettlement; }
}