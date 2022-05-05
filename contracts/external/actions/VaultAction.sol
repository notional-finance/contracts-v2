// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./ActionGuards.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";

contract VaultAction is ActionGuards {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using TokenHandler for Token;
    using SafeInt256 for int256;

    /// @notice Emitted when a new vault is listed or updated
    event VaultChange(address vaultAddress, bool enabled);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address vaultAddress, bool enabled);

    modifier allowAccountOrVault(address account, address vault) {
        require(msg.sender == account || msg.sender == vault, "Unauthorized");
        _;
    }

    /**
     * @notice Updates or lists a deployed vault along with its configuration.
     *
     * @param vaultAddress address of deployed vault
     * @param vaultConfig struct of vault configuration
     */
    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) external onlyOwner {
        // require(Address.isContract(vaultAddress));
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // Require that we have a significant amount of allowance set on the vault so we can transfer
        // asset tokens from the vault.
        require(IERC20(assetToken.tokenAddress).allowance(vaultAddress, address(this)) >= type(uint248).max);

        VaultConfiguration.setVaultConfig(vaultAddress, vaultConfig);
        bool enabled = (vaultConfig.flags & VaultConfiguration.ENABLED) == VaultConfiguration.ENABLED;
        emit VaultChange(vaultAddress, enabled);
    }

    /**
     * @notice Enables or disables a vault. If a vault is disabled, no one can enter
     * the vault anymore.
     *
     * @param vaultAddress address of deployed vault
     * @param enable bool if the vault should be enabled immediately
     */
    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external onlyOwner {
        VaultConfiguration.setVaultEnabledStatus(vaultAddress, enable);
        emit VaultPauseStatus(vaultAddress, enable);
    }

    /**
     * @notice Enters the account into the specified vault using the specified fCash
     * amount. Additional data is forwarded to the vault contract.
     *
     * @param account the address that will enter the vault
     * @param vault the vault to enter
     * @param fCash total amount of fCash to borrow to enter the vault
     * @param maxBorrowRate maximum interest rate to borrow at
     * @param vaultData additional data to pass to the vault contract
     * @return vaultSharesMinted
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        bool useUnderlying,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant returns (uint256) { 
        // Vaults cannot be entered if they are paused
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Not Enabled");

        // Vaults cannot be entered if they are in the settlement time period at the end of a quarter.
        require(!vaultConfig.isInSettlement(block.timestamp), "In Settlement");

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        // Do this first in case the vault has a matured vault position
        vaultAccount.settleVaultAccount(vaultConfig, block.timestamp);

        // This will update the account's cash balance in memory, this will establish the amount of
        // collateral that the vault account has. This method only transfers from the account, so approvals
        // must be set accordingly.
        vaultAccount.depositIntoAccount(account, vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);

        if (fCash > 0) {
            return _borrowAndEnterVault(vaultConfig, vaultAccount, fCash, maxBorrowRate, vaultData);
        } else {
            // If the account is not using any leverage we just enter the vault. No matter what the leverage
            // ratio will decrease in this case so we do not need to check vault health and the account will
            // not have to pay any nToken fees. This is useful for accounts that want to quickly and cheaply
            // deleverage their account without paying down debts.
            (/* */, /* */, uint256 vaultSharesMinted) = vaultAccount.enterAccountIntoVault(vaultConfig, vaultData);
            return vaultSharesMinted;
        }
    }

    /**
     * @notice Re-enters the vault at a longer dated maturity. There is no way to
     * partially re-enter a vault, the account's entire position will be rolled
     * forward.
     *
     * @param account the address that will reenter the vault
     * @param vault the vault to reenter
     * @param vaultSharesToRedeem the amount of vault shares to redeem for asset tokens
     * @param fCashToBorrow amount of fCash to borrow in the next maturity
     * @param minLendRate minimum lend rate to close out current position
     * @param maxBorrowRate maximum borrow rate to initiate new position
     * @param vaultData additional data to pass to the vault contract
     */
    function rollVaultPosition(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToBorrow,
        uint32 minLendRate,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant returns (uint256) {
        // Cannot enter a vault if it is not enabled
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Not Enabled");
        require(vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTER), "No Reenter");

        // Vaults can only be rolled during the settlement period
        require(vaultConfig.isInSettlement(block.timestamp), "Not in Settlement");
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);

        // Can only roll vaults that are in the current maturity
        require(vaultAccount.maturity == vaultConfig.getCurrentMaturity(block.timestamp), "Incorrect maturity");
        // Account must be borrowing fCash, otherwise they should exit.
        require(fCashToBorrow > 0, "Must Borrow");

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem);

        // Fully exit the current lending position
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            minLendRate,
            block.timestamp
        );

        // If the lending was unsuccessful then we cannot roll the position, the account cannot
        // have two fCash balances.
        require(vaultAccount.fCash == 0, "Failed Lend");

        // Borrows into the vault, paying nToken fees and checks borrow capacity
        return _borrowAndEnterVault(vaultConfig, vaultAccount, fCashToBorrow, maxBorrowRate, vaultData);
    }

    function _borrowAndEnterVault(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        uint256 fCashToBorrow,
        uint256 maxBorrowRate,
        bytes calldata vaultData
    ) private returns (uint256) {
        (AssetRateParameters memory assetRate, int256 totalVaultDebt) = vaultAccount.borrowIntoVault(
            vaultConfig,
            vaultConfig.getNextMaturity(block.timestamp),
            SafeInt256.toInt(fCashToBorrow).neg(),
            maxBorrowRate,
            block.timestamp
        );

        return _checkHealth(vaultAccount, vaultConfig, assetRate, totalVaultDebt, vaultData);
    }

    /// @notice Convenience method for borrowing and entering a vault, used in enterVault and rollVaultPosition
    function _checkHealth(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        AssetRateParameters memory assetRate,
        int256 totalVaultDebt,
        bytes calldata vaultData
    ) private returns (uint256) {
        // Transfers cash, sets vault account state, mints vault shares
        (
            int256 accountUnderlyingInternalValue,
            int256 vaultUnderlyingInternalValue,
            uint256 vaultSharesMinted
        ) = vaultAccount.enterAccountIntoVault(vaultConfig, vaultData);

        // Checks final vault and account leverage ratios
        vaultConfig.checkVaultAndAccountHealth(
            vaultUnderlyingInternalValue,
            totalVaultDebt,
            accountUnderlyingInternalValue,
            vaultAccount,
            assetRate
        );
    }

    /**
     * @notice Exits a vault by redeeming yield tokens, lending to offset fCash debt
     * and then withdrawing any earnings back to the account.
     *
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param vaultSharesToRedeem amount of vault tokens to exit
     * @param fCashToLend amount of fCash to lend
     * @param minLendRate the minimum rate to lend at
     * @param useUnderlying if vault shares should be redeemed to underlying
     */
    function exitVault(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        bool useUnderlying
    ) external allowAccountOrVault(account, vault) nonReentrant { 
        uint256 blockTime = block.timestamp;
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vault);
        
        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.redeemShares(vaultConfig, vaultSharesToRedeem);
        
        int256 netCashTransfer;
        if (vaultAccount.maturity <= blockTime) {
            vaultAccount.settleVaultAccount(vaultConfig, blockTime);
            // If the cash balance is negative, then this will attempt to pull cash from the account.
            netCashTransfer = vaultAccount.cashBalance.neg();
        } else {
            AssetRateParameters memory assetRate;
            (assetRate, netCashTransfer) = vaultAccount.lendToExitVault(
                vaultConfig,
                SafeInt256.toInt(fCashToLend),
                minLendRate,
                blockTime
            );
        
            // It's possible that the user redeems more vault shares than they lend (it is not always the case that they
            // will be reducing their leverage ratio here, so we check that this is the case).
            vaultConfig.checkVaultAndAccountHealth(vaultAccount, assetRate);
        }
        
        if (netCashTransfer < 0) {
            // It will be more common that accounts will be able to withdraw their profits
            vaultAccount.withdrawToAccount(vaultConfig.borrowCurrencyId, netCashTransfer, useUnderlying);
        } else if (netCashTransfer > 0) {
            // It's unlikely that an account will need to deposit to exit, so while this is slightly inefficient
            // it also won't be a very common execution path.
            Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
            int256 netCashTransferExternal = assetToken.convertToExternal(netCashTransfer);

            // TODO: we require deposits to be in asset tokens here for simplicity...is this going
            // to create problems?
            vaultAccount.depositIntoAccount(
                vaultAccount.account,
                vaultConfig.borrowCurrencyId,
                uint256(netCashTransferExternal), // overflow checked above
                true
            );
        }

        vaultAccount.setVaultAccount(vault);
    }

    /**
     * @notice Settles an entire vault, can only be called during an emergency stop out or during
     * the vault's defined settlement period. May be called multiple times during a vault term if
     * the vault has been stopped out early.
     *
     * @param vault the vault to settle
     * @param vaultData data to pass to the vault
     */
    function settleVault(
        address vault,
        bytes calldata vaultData
    ) external nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfig(vault);

        // TODO: pay the caller a fee for the transaction...
    }


}