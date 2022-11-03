// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;
pragma abicoder v2;

import {
    VaultConfigStorage,
    VaultConfig,
    VaultState,
    VaultAccount
} from "../../contracts/global/Types.sol";

interface IVaultAction {
    /// @notice Emitted when a new vault is listed or updated
    event VaultUpdated(address indexed vault, bool enabled, uint80 maxPrimaryBorrowCapacity);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address indexed vault, bool enabled);
    /// @notice Emitted when a vault's deleverage status is updated
    event VaultDeleverageStatus(address indexed vaultAddress, bool disableDeleverage);
    /// @notice Emitted when a secondary currency borrow capacity is updated
    event VaultUpdateSecondaryBorrowCapacity(address indexed vault, uint16 indexed currencyId, uint80 maxSecondaryBorrowCapacity);
    /// @notice Emitted when a vault has a shortfall upon settlement
    event VaultShortfall(address indexed vault, uint16 indexed currencyId, uint256 indexed maturity, int256 shortfall);
    /// @notice Emitted when a vault has an insolvency that cannot be covered by the
    /// cash reserve
    event ProtocolInsolvency(address indexed vault, uint16 indexed currencyId, uint256 indexed maturity, int256 shortfall);
    /// @notice Emitted when a vault fee is accrued via borrowing (denominated in asset cash)
    event VaultFeeAccrued(address indexed vault, uint16 indexed currencyId, uint256 indexed maturity, int256 reserveFee, int256 nTokenFee);
    /// @notice Emitted when the borrow capacity on a vault changes
    event VaultBorrowCapacityChange(address indexed vault, uint16 indexed currencyId, uint256 totalUsedBorrowCapacity);

    /// @notice Emitted when a vault executes a secondary borrow
    event VaultSecondaryBorrow(
        address indexed vault,
        address indexed account,
        uint16 indexed currencyId,
        uint256 maturity,
        uint256 debtSharesMinted,
        uint256 fCashBorrowed
    );

    /// @notice Emitted when a vault repays a secondary borrow
    event VaultRepaySecondaryBorrow(
        address indexed vault,
        address indexed account,
        uint16 indexed currencyId,
        uint256 maturity,
        uint256 debtSharesRepaid,
        uint256 fCashLent
    );

    /// @notice Emitted when secondary borrows are snapshot prior to settlement
    event VaultSecondaryBorrowSnapshot(
        address indexed vault,
        uint16 indexed currencyId,
        uint256 indexed maturity,
        int256 totalfCashBorrowedInPrimarySnapshot,
        int256 exchangeRate
    );

    /// @notice Emitted when a vault settles assets
    event VaultSettledAssetsRemaining(
        address indexed vault,
        uint256 indexed maturity,
        int256 remainingAssetCash,
        uint256 remainingStrategyTokens
    );

    event VaultStateUpdate(
        address indexed vault,
        uint256 indexed maturity,
        int256 totalfCash,
        uint256 totalAssetCash,
        uint256 totalStrategyTokens,
        uint256 totalVaultShares
    );

    event VaultSettled(
        address indexed vault,
        uint256 indexed maturity,
        int256 totalfCash,
        uint256 totalAssetCash,
        uint256 totalStrategyTokens,
        uint256 totalVaultShares,
        int256 strategyTokenValue
    );
    
    event VaultRedeemStrategyToken(
        address indexed vault,
        uint256 indexed maturity,
        int256 assetCashReceived,
        uint256 strategyTokensRedeemed
    );
    
    event VaultMintStrategyToken(
        address indexed vault,
        uint256 indexed maturity,
        uint256 assetCashDeposited,
        uint256 strategyTokensMinted
    );

    /** Vault Action Methods */

    /// @notice Governance only method to whitelist a particular vault
    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig,
        uint80 maxPrimaryBorrowCapacity
    ) external;

    /// @notice Governance only method to pause a particular vault
    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external;

    function setVaultDeleverageStatus(
        address vaultAddress,
        bool disableDeleverage
    ) external;

    /// @notice Governance only method to set the borrow capacity
    function setMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity
    ) external;

    /// @notice Governance only method to force a particular vault to deleverage
    function reduceMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external;

    /// @notice Governance only method to update a vault's secondary borrow capacity
    function updateSecondaryBorrowCapacity(
        address vaultAddress,
        uint16 secondaryCurrencyId,
        uint80 maxBorrowCapacity
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
        address account,
        uint256 maturity,
        uint256[2] calldata fCashToBorrow,
        uint32[2] calldata maxBorrowRate,
        uint32[2] calldata minRollLendRate
    ) external returns (uint256[2] memory underlyingTokensTransferred);

    function repaySecondaryCurrencyFromVault(
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 fCashToRepay,
        uint32 slippageLimit,
        bytes calldata callbackData
    ) external returns (bytes memory returnData);

    function initiateSecondaryBorrowSettlement(uint256 maturity)
        external returns (uint256[2] memory secondaryBorrowSnapshot);

    /// @notice Non-authenticated method that will set settlement values for a vault so that
    /// account holders can withdraw matured assets.
    function settleVault(address vault, uint256 maturity) external;

    /// @notice View method to get vault configuration
    function getVaultConfig(address vault) external view returns (VaultConfig memory vaultConfig);

    function getBorrowCapacity(address vault, uint16 currencyId)
        external view returns (uint256 totalUsedBorrowCapacity, uint256 maxBorrowCapacity);

    function getSecondaryBorrow(address vault, uint16 currencyId, uint256 maturity) 
        external view returns (
            uint256 totalfCashBorrowed,
            uint256 totalAccountDebtShares,
            uint256 totalfCashBorrowedInPrimarySnapshot
        );

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

    event VaultEnterPosition(
        address indexed vault,
        address indexed account,
        uint256 indexed maturity,
        uint256 fCashBorrowed
    );

    event VaultRollPosition(
        address indexed vault,
        address indexed account,
        uint256 indexed newMaturity,
        uint256 fCashBorrowed
    );

    event VaultExitPostMaturity(
        address indexed vault,
        address indexed account,
        uint256 indexed maturity,
        uint256 underlyingToReceiver
    );

    event VaultExitPreMaturity(
        address indexed vault,
        address indexed account,
        uint256 indexed maturity,
        uint256 fCashToLend,
        uint256 vaultSharesToRedeem,
        uint256 underlyingToReceiver
    );

    event VaultDeleverageAccount(
        address indexed vault,
        address indexed account,
        uint256 vaultSharesToLiquidator,
        int256 fCashRepaid
    );

    event VaultLiquidatorProfit(
        address indexed vault,
        address indexed account,
        address indexed liquidator,
        uint256 vaultSharesToLiquidator,
        bool transferSharesToLiquidator
    );

    event VaultEnterMaturity(
        address indexed vault,
        uint256 indexed maturity,
        address indexed account,
        uint256 underlyingTokensDeposited,
        uint256 cashTransferToVault,
        uint256 strategyTokenDeposited,
        uint256 vaultSharesMinted
    );
    
    /**
     * @notice Borrows a specified amount of fCash in the vault's borrow currency and deposits it
     * all plus the depositAmountExternal into the vault to mint strategy tokens.
     *
     * @param account the address that will enter the vault
     * @param vault the vault to enter
     * @param depositAmountExternal some amount of additional collateral in the borrowed currency
     * to be transferred to vault
     * @param maturity the maturity to borrow at
     * @param fCash amount to borrow
     * @param maxBorrowRate maximum interest rate to borrow at
     * @param vaultData additional data to pass to the vault contract
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        uint256 maturity,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external payable returns (uint256 strategyTokensAdded);

    /**
     * @notice Re-enters the vault at a longer dated maturity. The account's existing borrow
     * position will be closed and a new borrow position at the specified maturity will be
     * opened. All strategy token holdings will be rolled forward.
     *
     * @param account the address that will reenter the vault
     * @param vault the vault to reenter
     * @param fCashToBorrow amount of fCash to borrow in the next maturity
     * @param maturity new maturity to borrow at
     */
    function rollVaultPosition(
        address account,
        address vault,
        uint256 fCashToBorrow,
        uint256 maturity,
        uint256 depositAmountExternal,
        uint32 minLendRate,
        uint32 maxBorrowRate,
        bytes calldata enterVaultData
    ) external payable returns (uint256 strategyTokensAdded);

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
     * @param exitVaultData passed to the vault during exit
     * @return underlyingToReceiver amount of underlying tokens returned to the receiver on exit
     */
    function exitVault(
        address account,
        address vault,
        address receiver,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        bytes calldata exitVaultData
    ) external payable returns (uint256 underlyingToReceiver);

    /**
     * @notice If an account is below the minimum collateral ratio, this method wil deleverage (liquidate)
     * that account. `depositAmountExternal` in the borrow currency will be transferred from the liquidator
     * and used to offset the account's debt position. The liquidator will receive either vaultShares or
     * cash depending on the vault's configuration.
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param liquidator the address that will receive profits from liquidation
     * @param depositAmountExternal amount of cash to deposit
     * @param transferSharesToLiquidator transfers the shares to the liquidator instead of redeeming them
     * @param redeemData calldata sent to the vault when redeeming liquidator profits
     * @return profitFromLiquidation amount of vaultShares or cash received from liquidation
     */
    function deleverageAccount(
        address account,
        address vault,
        address liquidator,
        uint256 depositAmountExternal,
        bool transferSharesToLiquidator,
        bytes calldata redeemData
    ) external returns (uint256 profitFromLiquidation);

    function getVaultAccount(address account, address vault) external view returns (VaultAccount memory);
    function getVaultAccountDebtShares(address account, address vault) external view returns (
        uint256 debtSharesMaturity,
        uint256[2] memory accountDebtShares,
        uint256 accountStrategyTokens
    );
    function getVaultAccountCollateralRatio(address account, address vault) external view returns (
        int256 collateralRatio,
        int256 minCollateralRatio,
        int256 maxLiquidatorDepositAssetCash,
        uint256 vaultSharesToLiquidator
    );
}

interface IVaultController is IVaultAccountAction, IVaultAction {}