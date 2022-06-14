// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;

interface IStrategyVault {

    function decimals() external view returns (uint8);
    function name() external view returns (string memory);

    // Tells a vault to deposit some amount of tokens from Notional and mint strategy tokens with it.
    function depositFromNotional(
        address account,
        uint256 depositAmount,
        uint256 maturity,
        bytes calldata data
    ) external returns (uint256 strategyTokensMinted);

    // Tells a vault to redeem some amount of strategy tokens from Notional and transfer the resulting asset cash
    function redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) external;

    function convertStrategyToUnderlying(uint256 strategyTokens, uint256 maturity) external view returns (uint256 underlyingValue);

    function repaySecondaryBorrowCallback(uint256 assetCashRequired, bytes calldata data) external returns (bytes memory returnData);
}