// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;

interface IStrategyVault {

    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function strategy() external view returns (bytes4 strategyId);

    // Tells a vault to deposit some amount of tokens from Notional and mint strategy tokens with it.
    function depositFromNotional(
        address account,
        uint256 depositAmount,
        uint256 maturity,
        bytes calldata data
    ) external payable returns (uint256 strategyTokensMinted);

    // Tells a vault to redeem some amount of strategy tokens from Notional and transfer the resulting asset cash
    function redeemFromNotional(
        address account,
        address receiver,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 underlyingToRepayDebt,
        bytes calldata data
    ) external returns (uint256 transferToReceiver);

    function convertStrategyToUnderlying(
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) external view returns (int256 underlyingValue);

    function repaySecondaryBorrowCallback(
        address token,
        uint256 underlyingRequired,
        bytes calldata data
    ) external returns (bytes memory returnData);
}