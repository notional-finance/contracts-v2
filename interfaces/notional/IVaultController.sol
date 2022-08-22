// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;
pragma abicoder v2;

import {
    VaultConfigStorage,
    VaultConfig,
    VaultState,
    VaultAccount,
    RollVaultOpts
} from "../../contracts/global/Types.sol";

interface IVaultAction {
    /// @notice Emitted when a new vault is listed or updated
    event VaultChange(address vaultAddress, bool enabled);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address vaultAddress, bool enabled);
    /// @notice Emitted when a vault has an insolvency that cannot be covered by the
    /// cash reserve
    event ProtocolInsolvency(uint16 currencyId, address vault, int256 shortfall);

    /** Vault Action Methods */

    /// @notice Governance only method to whitelist a particular vault
    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) external;

    /// @notice Governance only method to pause a particular vault
    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external;

    /// @notice Governance only method to force a particular vault to deleverage
    function reduceMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external;

    /// @notice Vault authenticated method that takes asset cash from the pool and mints strategy tokens
    function depositVaultCashToStrategyTokens(
        uint256 maturity,
        uint256 assetCashToDepositExternal,
        bytes calldata vaultData
    ) external;

    /// @notice Vault authenticated method that takes strategy tokens and mints asset cash to the pool
    function redeemStrategyTokensToCash(
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    );

    function borrowSecondaryCurrencyToVault(
        uint16 currencyId,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint32 slippageLimit
    ) external returns (uint256 underlyingTokensTransferred);

    function repaySecondaryCurrencyFromVault(
        uint16 currencyId,
        uint256 maturity,
        uint256 netfCash,
        uint32 slippageLimit
    ) external returns (uint256 assetTokensRequired);

    /// @notice Non-authenticated method that will set settlement values for a vault so that
    /// account holders can withdraw matured assets.
    function settleVault(address vault, uint256 maturity) external;

    /// @notice View method to get vault configuration
    function getVaultConfig(address vault) external view returns (VaultConfig memory vaultConfig);

    /// @notice View method to get vault state
    function getVaultState(address vault, uint256 maturity) external view returns (VaultState memory vaultState);

    /// @notice View method to get the current amount of cash remaining to settle the vault
    function getCashRequiredToSettle(
        address vault,
        uint256 maturity
    ) external view returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    );
}

interface IVaultAccountAction {
    
    /**
     * @notice Borrows a specified amount of fCash in the vault's borrow currency and deposits it
     * all plus the depositAmountExternal into the vault to mint strategy tokens.
     *
     * @param account the address that will enter the vault
     * @param vault the vault to enter
     * @param depositAmountExternal some amount of additional collateral in the borrowed currency
     * to be transferred to vault
     * @param maturity the maturity to borrow at
     * @param useUnderlying true if the account will transfer underlying tokens
     * @param fCash amount to borrow
     * @param maxBorrowRate maximum interest rate to borrow at
     * @param vaultData additional data to pass to the vault contract
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        uint256 maturity,
        bool useUnderlying,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external;

    /**
     * @notice Re-enters the vault at a longer dated maturity. The account's existing borrow
     * position will be closed and a new borrow position at the specified maturity will be
     * opened. All strategy token holdings will be rolled forward.
     *
     * @param account the address that will reenter the vault
     * @param vault the vault to reenter
     * @param fCashToBorrow amount of fCash to borrow in the next maturity
     * @param maturity new maturity to borrow at
     * @param opts struct with slippage limits and data to send to vault
     */
    function rollVaultPosition(
        address account,
        address vault,
        uint256 fCashToBorrow,
        uint256 maturity,
        RollVaultOpts calldata opts
    ) external;

    /**
     * @notice Prior to maturity, allows an account to withdraw their position from the vault. Will
     * redeem some number of vault shares to the borrow currency and close the borrow position by
     * lending `fCashToLend`. Any shortfall in cash from lending will be transferred from the account,
     * any excess profits will be transferred to the account.
     *
     * Post maturity, will net off the account's debt against vault cash balances and redeem all remaining
     * strategy tokens back to the borrowed currency and transfer the profits to the account.
     *
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param vaultSharesToRedeem amount of vault tokens to exit, only relevant when exiting pre-maturity
     * @param fCashToLend amount of fCash to lend
     * @param minLendRate the minimum rate to lend at
     * @param useUnderlying if vault shares should be redeemed to underlying
     * @param exitVaultData passed to the vault during exit
     */
    function exitVault(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        bool useUnderlying,
        bytes calldata exitVaultData
    ) external;

    /**
     * @notice If an account is below the minimum collateral ratio, this method wil deleverage (liquidate)
     * that account. `depositAmountExternal` in the borrow currency will be transferred from the liquidator
     * and used to offset the account's debt position. The liquidator will receive either vaultShares or
     * cash depending on the vault's configuration.
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param liquidator the address that will receive profits from liquidation
     * @param depositAmountExternal amount of cash to deposit
     * @param useUnderlying true if we should use the underlying token
     * @param redeemData calldata sent to the vault when redeeming liquidator profits
     * @return profitFromLiquidation amount of vaultShares or cash received from liquidation
     */
    function deleverageAccount(
        address account,
        address vault,
        address liquidator,
        uint256 depositAmountExternal,
        bool useUnderlying,
        bytes calldata redeemData
    ) external returns (uint256 profitFromLiquidation);

    function getVaultAccount(address account, address vault) external view returns (VaultAccount memory);
    function getVaultAccountMaturity(address account, address vault) external view returns (uint256 maturity);
    function getVaultAccountCollateralRatio(address account, address vault) external view returns (
        int256 collateralRatio,
        int256 minCollateralRatio
    );
}

interface IVaultController is IVaultAccountAction, IVaultAction {}