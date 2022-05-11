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

    function getVaultConfig(
        address vault
    ) external view returns (VaultConfig memory vaultConfig);

    function getVaultState(
        address vault,
        uint256 maturity
    ) external view returns (VaultState memory vaultState);

    function getCurrentVaultState(
        address vault
    ) external view returns (VaultState memory vaultState);

    function getCurrentVaultMaturity(
        address vault
    ) external view returns (uint256);

    function getCashRequiredToSettle(
        address vault,
        uint256 maturity
    ) external view returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    );

    function getCashRequiredToSettleCurrent(
        address vault
    ) external view returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    );
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

    function getVaultAccount(address account, address vault) external view returns (VaultAccount memory);
    function getVaultAccountMaturity(address account, address vault) external view returns (uint256 maturity);
    function getVaultAccountLeverage(address account, address vault) external view returns (
        int256 leverageRatio,
        int256 maxLeverageRatio
    );
}

interface IVaultController is IVaultAccountAction, IVaultAction {}