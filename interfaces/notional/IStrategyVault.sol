// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;

import "../IERC20.sol";

interface IStrategyVaultCustom {

    // Tells a vault to deposit some amount of tokens from Notional and mint strategy tokens with it.
    function depositFromNotional(uint256 depositAmount, uint256 maturity, bytes calldata data) external returns (uint256 strategyTokensMinted);
    // Tells a vault to redeem some amount of strategy tokens from Notional and transfer the resulting asset cash
    function redeemFromNotional(uint256 strategyTokens, uint256 maturity, bytes calldata data) external;

    function isInSettlement() external view returns (bool);
    function canSettleMaturity(uint256 maturity) external view returns (bool);
    function convertStrategyToUnderlying(uint256 strategyTokens) external view returns (uint256 underlyingValue);
}

interface IStrategyVault is IStrategyVaultCustom, IERC20  {}