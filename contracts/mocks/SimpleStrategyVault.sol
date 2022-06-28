// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../strategyVaults/BaseStrategyVault.sol";

contract SimpleStrategyVault is BaseStrategyVault {
    event SecondaryBorrow(uint256[2] underlyingTokensTransferred);

    bool internal _reenterNotional;
    uint256 internal _tokenExchangeRate;
    uint16 internal _secondaryCurrency;
    function setReenterNotional(bool s) external { _reenterNotional = s; }
    function setExchangeRate(uint256 e) external { _tokenExchangeRate = e; }
    function setSecondary(uint16 c) external { _secondaryCurrency = c; }

    constructor(
        string memory name_,
        address notional_,
        uint16 borrowCurrencyId_
    ) BaseStrategyVault(name_, notional_, borrowCurrencyId_) { }

    // Vaults need to implement these two methods
    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 strategyTokensMinted) {
        strategyTokensMinted = (deposit * 1e18) / (_tokenExchangeRate * 1e10);
        if (_reenterNotional) {
            UNDERLYING_TOKEN.approve(address(NOTIONAL), deposit);
            NOTIONAL.depositUnderlyingToken(address(this), BORROW_CURRENCY_ID, deposit);
        }
    }

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 assetTokensToTransfer) {
        return strategyTokens * _tokenExchangeRate * 1e10 / 1e18;
    }

    function _repaySecondaryBorrowCallback(
        address token, uint256 underlyingTokensRequired, bytes calldata /* data */
    ) internal override returns (bytes memory returnData) {
        if (token == address(0)) {
            payable(address(NOTIONAL)).transfer(underlyingTokensRequired);
        } else {
            ERC20(token).transfer(address(NOTIONAL), underlyingTokensRequired);
        }
    }

    function convertStrategyToUnderlying(
        address account, uint256 strategyTokens, uint256 maturity
    ) public view override returns (int256 underlyingValue) {
        return int256((strategyTokens * _tokenExchangeRate * 1e10) / 1e18);
    }

    function borrowSecondaryCurrency(
        address account,
        uint256 maturity,
        uint256[2] calldata fCashToBorrow,
        uint32[2] calldata maxBorrowRate,
        uint32[2] calldata minRollLendRate
    ) external {
        uint256[2] memory underlyingTokensTransferred = NOTIONAL.borrowSecondaryCurrencyToVault(
            account, maturity, fCashToBorrow, maxBorrowRate, minRollLendRate 
        );
        emit SecondaryBorrow(underlyingTokensTransferred);
    }

    function repaySecondaryCurrency(
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 accountDebtShares,
        uint32 slippageLimit
    ) external {
        NOTIONAL.repaySecondaryCurrencyFromVault(
            account, currencyId, maturity, accountDebtShares, slippageLimit, ""
        );
    }
}