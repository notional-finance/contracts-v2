// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.8.11;
pragma abicoder v2;

import "./BaseStrategyVault.sol";

contract SimpleStrategyVault is BaseStrategyVault {
    event SecondaryBorrow(int256[2] underlyingTokensTransferred);

    function strategy() external pure override returns (bytes4) {
        return bytes4(keccak256("SimpleStrategyVault"));
    }

    bool internal _reenterNotional;
    uint256 internal _tokenExchangeRate;
    uint16 internal _secondaryCurrency;
    uint256 public _underlyingDecimals;

    function setReenterNotional(bool s) external { _reenterNotional = s; }
    function setExchangeRate(uint256 e) external { _tokenExchangeRate = e; }
    function setSecondary(uint16 c) external { _secondaryCurrency = c; }
    function tokenExchangeRate() external view returns (uint256) { return _tokenExchangeRate; }

    constructor(
        string memory name_,
        address notional_,
        uint16 borrowCurrencyId_
    ) BaseStrategyVault(name_, notional_, borrowCurrencyId_) {
        (
            Token memory assetToken,
            Token memory underlyingToken
        ) = NotionalProxy(notional_).getCurrency(borrowCurrencyId_);
        _underlyingDecimals = uint256(underlyingToken.decimals);
    }

    // Vaults need to implement these two methods
    function _depositFromNotional(
        address /* account */,
        uint256 deposit,
        uint256 /* maturity */,
        bytes calldata /* data */
    ) internal override returns (uint256 strategyTokensMinted) {
        strategyTokensMinted = (deposit * 1e18 * 1e8) / (_tokenExchangeRate * _underlyingDecimals);
        if (_reenterNotional) {
            UNDERLYING_TOKEN.approve(address(NOTIONAL), deposit);
            NOTIONAL.depositUnderlyingToken(address(this), BORROW_CURRENCY_ID, deposit);
        }
    }

    function _redeemFromNotional(
        address /* account */,
        uint256 strategyTokens,
        uint256 /* maturity */,
        uint256 /* underlyingToRepay */,
        bytes calldata /* data */
    ) internal view override returns (uint256 assetTokensToTransfer) {
        return strategyTokens * _tokenExchangeRate * _underlyingDecimals / (1e18 * 1e8);
    }

    function convertStrategyToUnderlying(
        address /* account */, uint256 strategyTokens, uint256 /* maturity */
    ) public view override returns (int256 underlyingValue) {
        return int256((strategyTokens * _tokenExchangeRate * _underlyingDecimals) / (1e18 * 1e8));
    }

    function borrowSecondaryCurrency(
        address account,
        uint256 maturity,
        uint256[2] calldata fCashToBorrow,
        uint32[2] calldata maxBorrowRate,
        uint32[2] calldata minRollLendRate
    ) external {
        int256[2] memory underlyingTokensTransferred = NOTIONAL.borrowSecondaryCurrencyToVault(
            account, maturity, fCashToBorrow, maxBorrowRate, minRollLendRate 
        );
        emit SecondaryBorrow(underlyingTokensTransferred);
    }

    function setApproval(address token) external {
        ERC20(token).approve(address(NOTIONAL), type(uint256).max);
    }

    function repaySecondaryCurrency(
        address account,
        uint256 maturity,
        uint256[2] calldata debtToRepay,
        uint32[2] calldata slippageLimit,
        uint256 msgValue
    ) external {
        NOTIONAL.repaySecondaryCurrencyFromVault{value: msgValue}(
            account, maturity, debtToRepay, slippageLimit
        );
    }
}