// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;

interface IStrategyVault {

    /// @notice MUST always return 8. All strategy vaults must use 8 decimal precision. Where
    /// underlying yield strategies use larger precision, vaults will round down at 8 decimals.
    function decimals() external view returns (uint8);

    /// @notice A specific name for an individual vault instance, to be displayed on a user interface.
    /// SHOULD include some indication of the borrowed currency in the case of multiple vault instances
    /// that borrow different currencies.
    function name() external view returns (string memory);

    /// @notice A unique 4 byte identifier for the strategy. All instances of a vault that implement
    /// the same yield strategy must return the same 4 byte identifier. Allows user interfaces to
    /// identify any additional front end code that must be loaded for this vault.
    function strategy() external view returns (bytes4 strategyId);

    /// @notice Will be called after an account has executed a borrow and `depositAmount` has been
    /// transferred to the contract. The vault will then enter into it's yield strategy position and
    /// return the strategy tokens minted for this particular account.
    /// @dev MUST revert if called by any other contract than Notional. 
    function depositFromNotional(
        address account,
        uint256 depositAmount,
        uint256 maturity,
        bytes calldata data
    ) external payable returns (uint256 strategyTokensMinted);

    /// @notice Called when an account is exiting a position and the vault must transfer tokens
    /// back to Notional in order to repay debts. The vault will redeem `strategyTokens` for underlying
    /// tokens and send `underlyingToRepayDebt` back to the Notional. Any remaining tokens must be
    /// sent to the `receiver` address.
    /// @dev MUST revert if called by any other contract than Notional.
    /// @return transferToReceiver the amount of tokens transferred to the receiver so that Notional
    /// can log the event.
    function redeemFromNotional(
        address account,
        address receiver,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 underlyingToRepayDebt,
        bytes calldata data
    ) external returns (uint256 transferToReceiver);

    /// @notice Called in order to get the value of strategy tokens denominated in the borrowed
    /// currency.
    function convertStrategyToUnderlying(
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) external view returns (int256 underlyingValue);

    /// @notice If vaults are borrowing in secondary currencies, this hook will be called by Notional
    /// to instruct the vault on how much secondary currency must be repaid to Notional.
    /// @dev MUST revert if called by any other contract than Notional.
    function repaySecondaryBorrowCallback(
        address token,
        uint256 underlyingRequired,
        bytes calldata data
    ) external returns (bytes memory returnData);
}