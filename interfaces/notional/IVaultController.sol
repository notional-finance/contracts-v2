// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;
pragma abicoder v2;

import "../../contracts/global/Types.sol";

interface IVaultAction {
    /// @notice Emitted when a new vault is listed or updated
    event VaultChange(address vaultAddress, bool enabled);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address vaultAddress, bool enabled);

    /** Vault Action Methods */

    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) external;

    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external;

    function settleVault(
        address vault,
        uint256 maturity,
        address[] calldata settleAccounts,
        uint256[] calldata vaultSharesToRedeem,
        uint256 nTokensToRedeem
    ) external;
}

interface IVaultAccountAction {

    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        bool useUnderlying,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external;

    function rollVaultPosition(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToBorrow,
        RollVaultOpts calldata opts
    ) external;

    function exitVault(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        bool useUnderlying,
        bytes calldata exitVaultData
    ) external;

    function deleverageAccount(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        bytes calldata exitVaultData
    ) external;
}

interface IVaultController is IVaultAccountAction, IVaultAction {}