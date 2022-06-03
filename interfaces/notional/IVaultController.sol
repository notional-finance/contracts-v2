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

    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) external;

    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external;

    function reduceMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external;

    function settleVault(
        address vault,
        uint256 maturity,
        address[] calldata settleAccounts,
        uint256[] calldata vaultSharesToRedeem,
        bytes calldata redeemCallData
    ) external;

    function depositVaultCashToStrategyTokens(
        uint256 maturity,
        uint256 assetCashToDepositExternal,
        bytes calldata vaultData
    ) external;

    function redeemStrategyTokensToCash(
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    );

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
        address receiver,
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