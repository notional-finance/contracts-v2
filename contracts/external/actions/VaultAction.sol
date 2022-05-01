// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./ActionGuards.sol";

contract VaultAction is ActionGuards {
    using VaultConfiguration for VaultConfig;

    /// @notice Emitted when a new vault is listed or updated
    event VaultChange(address vaultAddress, bool enabled);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address vaultAddress, bool enabled);

    modifier allowAccountOrVault(address account, address vault) {
        require(msg.sender == account || msg.sender == vault, "Unauthorized");
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
        require(Address.isContract(vaultAddress));
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // Require that we have a significant amount of allowance set on the vault so we can transfer
        // asset tokens from the vault.
        require(IERC20(assetToken.tokenAddress).allowance(vaultAddress, address(this)) >= type(uint248).max);

        vaultConfig.setVaultConfiguration(vaultAddress);
        bool enabled = vaultConfig.getFlag(VaultFlags.ENABLED);
        emit VaultListed(vaultAddress, enabled);
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
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vaultAddress);

        if (enable) {
            vaultConfig.flags = vaultConfig.flags | VaultFlags.ENABLED;
        } else {
            vaultConfig.flags = vaultConfig.flags & ~VaultFlags.ENABLED;
        }
        vaultConfig.setVaultConfiguration(vaultAddress);

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
     * @return vaultTokensMinted
     */
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        bool useUnderlying,
        uint256 fCash,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant returns (uint256 vaultTokensMinted) { 
        // Vaults cannot be entered if they are paused
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vault);
        require(vaultConfig.getFlag(VaultFlags.ENABLED), "Not Enabled");

        // Vaults cannot be entered if they are in the settlement time period at the end of a quarter.
        uint256 blockTime = block.timestamp;
        require(!vaultConfig.isInSettlement(blockTime), "In Settlement");

        VaultAccount memory vaultAccount = VaultAccount.getVaultAccount(account, vault);
        // Do this first in case the vault has a matured vault position
        vaultAccount.settleVaultAccount(vaultConfig, blockTime);

        // TODO: allow this to transfer from the vault as well?
        // This will update the account's cash balance in memory, this will establish the amount of
        // collateral that the vault account has.
        vaultAccount.depositFromAccount(vaultConfig.borrowCurrencyId, depositAmountExternal, useUnderlying);
        vaultAccount.borrowIntoVault(
            vaultConfig,
            vaultConfig.getCurrentMaturity(blockTime),
            SafeInt256.toInt(fCash).neg(),
            maxBorrowRate,
            blockTime
        );

        // At this point the vault must have some cash balance to enter the vault with. There are three
        // sources of this potential cash balance:
        //  - settling a matured vault account
        //  - deposits from the account
        //  - borrowing into the vault
        require(vaultAccount.cashBalance > 0);

        // Now, push the entire cash balance into the vault and let the vault know that this account
        // needs to enter a position.
        (
            int256 assetCashToVaultExternal,
            /* int256 actualTransferInternal */
        ) = vaultConfig.transferVault(vaultAccount.cashBalance.neg());
        vaultAccount.cashBalance = 0;
        vaultAccount.setVaultAccount(account, vaultConfig.vaultAddress);

        // This call will tell the vault that a particular account has entered and it will
        // enter it's yield position. It will then check that the vault is under it's leverage
        // ratio and max capacity.
        return vaultConfig.enterVaultAndCheckHealth(account, assetCashToVaultExternal, vaultData);
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
     * @param withdrawTo address to receive withdrawn funds
     */
    function exitVault(
        address account,
        address vault,
        uint256 vaultSharesToRedeem,
        uint256 fCashToLend,
        uint32 minLendRate,
        address withdrawTo
    ) external allowAccountOrVault(account, vault) nonReentrant { 
        uint256 blockTime = block.timestamp;
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vault);
        VaultAccount memory vaultAccount = VaultAccount.getVaultAccount(account, vault);
        
        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.redeemShares(vault, vaultSharesToRedeem);
        
        int256 netCashTransfer;
        if (vaultAccount.maturity <= blockTime) {
            vaultAccount.settleVaultAccount(vaultConfig, blockTime);
            // If the cash balance is negative, then this will attempt to pull cash from the account.
            netCashTransfer = vaultAccount.cashBalance.neg();
        } else {
            netCashTransfer = vaultAccount.lendToExitVault(
                vaultConfig,
                SafeInt256.toInt(fCash),
                minLendRate,
                blockTime
            );
        }
        
        if (netCashTransfer > 0) {
            // TODO: this takes an external amount...
            vaultAccount.depositFromAccount(vaultConfig.borrowCurrencyId, netCashTransfer, useUnderlying);
        } else if (netCashTransfer < 0) {
            vaultAccount.withdrawToAccount(vaultConfig.borrowCurrencyId, netCashTransfer, useUnderlying);
        }
        
        // It's possible that the user redeems more vault shares than they lend (it is not always the case that they
        // will be reducing their leverage ratio here, so we check that this is the case).
        int256 leverageRatio = _calculateLeverage(vaultAccount, vaultConfig, assetRate);
        require(leverageRatio <= vaultConfig.maxLeverageRatio, "Excess leverage");
    }

    /**
     * @notice Re-enters the vault at a longer dated maturity. There is no way to
     * partially re-enter a vault, the account's entire position will be rolled
     * forward.
     *
     * @param account the address that will reenter the vault
     * @param vault the vault to reenter
     * @param fCashToEnter the total amount of fCash to enter in the next vault term
     * @param minLendRate minimum lend rate to close out current position
     * @param maxLendRate maximum borrow rate to initiate new position
     * @param vaultSharesToExit optional parameter for selling part of the vault shares to cover
     * the cost to exit the position, any remaining cost will be transferred from the account
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
    ) external allowAccountOrVault(account, vault) nonReentrant {
        // Cannot enter a vault if it is not enabled
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vaultAddress);
        require(vaultConfig.getFlag(VaultFlags.ENABLED), "Not Enabled");
        require(vaultConfig.getFlag(VaultFlags.ALLOW_REENTER), "No Reenter");

        // Vaults can only be rolled during the settlement period
        uint256 blockTime = block.timestamp;
        require(vaultConfig.isInSettlement(blockTime), "Not in Settlement");
        VaultAccount memory vaultAccount = VaultAccount.getVaultAccount(account, vault);

        // Can only roll vaults that are in the current maturity
        require(vaultAccount.maturity == vaultConfig.getCurrentMaturity(), "Incorrect maturity");

        // Exit the vault first, redeeming the amount of vault shares and crediting the amount raised
        // back into the cash balance.
        vaultAccount.redeemShares(vault, vaultSharesToRedeem);

        // Fully exit the current lending position
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultAccount.fCash.neg(), // must fully exit the fCash position
            minLendRate,
            blockTime
        );

        // If the lending was unsuccessful then we cannot roll the position, the account cannot have two
        // fCash balances.
        require(vaultAccount.fCash == 0, "Failed Lend");

        // Execute the borrow in the next maturity 
        vaultAccount.borrowIntoVault(
            vaultConfig,
            vaultConfig.getNextMaturity(),
            SafeInt256.toInt(fCashToBorrow).neg(),
            maxBorrowRate,
            blockTime
        );
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
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vaultAddress);

        // TODO: pay the caller a fee for the transaction...
    }
}