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
        VaultConfig memory vaultConfig
    ) external onlyOwner {
        // require vault contract is deployed
        // require that vault has no account context
        // require that vault has set an allowance for Notional to pull funds

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
        uint256 fCash,
        uint32 maxBorrowRate,
        // bytes calldata controllerData, NOTE: not sure if we need this
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant returns (uint256 vaultTokensMinted) { 
        // Vaults cannot be entered if they are paused
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vaultAddress);
        require(vaultConfig.getFlag(VaultFlags.ENABLED), "Not Enabled");

        // Vaults cannot be entered if they are in the settlement time period at the end of a quarter.
        uint256 blockTime = block.timestamp;
        require(!vaultConfig.isInSettlement(blockTime), "In Settlement");

        // These are in internal precision
        (
            int256 assetCashCollateralRequired,
            int256 assetCashToVault
        ) = vaultConfig.enterCurrentVault(vault, account, fCash, maxBorrowRate, blockTime);
        
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        int256 assetCashToVaultExternal = assetToken.convertToExternal(assetCashToVault);
        int256 assetCashCollateralRequiredExternal = assetToken.convertToExternal(assetCashCollateralRequired);

        // Transfer in the required collateral...must have it in asset tokens
        // TODO: can this value be negative? If so what do we do?
        require(assetCashCollateralRequired >= 0);
        // TODO: need to check the return value
        int256 assetCashCollateralRequiredExternal = assetToken.transfer(account, vaultConfig.borrowCurrencyId, assetCashCollateralRequiredExternal);

        // The negative signifies that the transfer will exit Notional, returns the actual amount of tokens transferred.
        int256 assetCashToVaultExternal = assetToken.transfer(vault, vaultConfig.borrowCurrencyId, assetCashToVaultExternal.neg());

        // This call will tell the vault that a particular account has entered and it will
        // enter it's yield position. It will return the vault shares the account currently
        // has.
        return ILeveredVault(vault).enterVault(account, assetCashToVaultExternal, vaultData);
    }

    /**
     * @notice Exits a vault by redeeming yield tokens, lending to offset fCash debt
     * and then withdrawing any earnings back to the account.
     *
     * @param account the address that will exit the vault
     * @param vault the vault to enter
     * @param vaultShareToExit amount of vault tokens to exit
     * @param minLendRate the minimum rate to lend at
     * @param withdrawTo address to receive withdrawn funds
     */
    function exitVault(
        address account,
        address vault,
        uint256 vaultShareToExit,
        uint32 minLendRate,
        address withdrawTo
    ) public allowAccountOrVault(account, vault) nonReentrant { 
        // Accounts can always exit a vault whether or not it is enabled. Exiting a vault will cause
        // the account's yield farming position to be settled back to the borrow currency, this will
        // likely incur some slippage and other transaction costs.

        // An account can only be in a single vault maturity at at time. If they have allowed a vault
        // to term mature, then their profits will be held in asset tokens in the borrow currency (their
        // matured position will have been settled). They must first exit their existing position and
        // then re-enter the vault. Calling "rollVaultPosition" before maturity will allow them to exit
        // and enter the next vault term and avoid settling out their yield farming position.
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vaultAddress);

        // The amount of fCash to exit is proportional to the share of the vault to exit
        uint256 vaultBalance = ILeveragedVault(vault).balanceOf(account);
        require(vaultBalance >= vaultShareToExit, "Insufficient balance");
        uint256 fCashShare = vaultBalance.mul(Constants.VAULT_TOKEN_PRECISION).div(vaultShareToExit);

        // It's possible that this is negative, in that case the account is able to exit the vault at a profit
        // possibly due to interest rate increases since the account entered.
        int256 assetCashCostToExitInternal = vaultConfig.exitVault(account, fCashShare, minLendRate, blockTime);

        // Returns the amount of cash raised by the exit, does not transfer the tokens, this returns the
        // amount of borrow currency asset tokens the account has a claim on in the levered vault. These
        // tokens must be available at this point in time.
        int256 assetCashHoldingsExternal = ILeveredVault(vault).exitVault(account, vaultShareToExit);
        
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // Transfer the profits from exiting the vault into Notional, requires that the vault has
        // set an allowance on Notional to transfer tokens in.
        if (assetCashHoldingsExternal > 0) {
            // NOTE: this is somewhat dangerous if the vault decided to revoke this allowance, on the flip side
            // it's also dangerous if the vault does not transfer the proper amount of tokens...
            assetCashHoldingsExternal = assetToken.transfer(vault, vaultConfig.borrowCurrencyId, assetCashHoldingsExternal);
        }

        int256 netProfitInternal = assetToken.convertToInternal(assetCashHoldingsExternal).sub(assetCashCostToExitInternal);
        if (netProfitInternal > 0) {
            // Send withdrawTo account the profits from the vault
            assetToken.transfer(withdrawTo, vaultConfig.borrowCurrencyId, netProfitInternal.neg());
        } else {
            // Vault has suffered a loss, we would need to redeem nTokens to cover the shortfall but we don't
            // do that here. That must be done in a separate method.
        }
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
        uint256 fCashToEnter,
        uint32 minLendRate,
        uint32 maxBorrowRate,
        uint256 vaultSharesToExit,
        bytes calldata vaultData
    ) external allowAccountOrVault(account, vault) nonReentrant {
        // Cannot enter a vault if it is not enabled
        VaultConfig memory vaultConfig = VaultConfiguration.getVault(vaultAddress);
        require(vaultConfig.getFlag(VaultFlags.ENABLED), "Not Enabled");
        require(vaultConfig.getFlag(VaultFlags.ALLOW_REENTER), "No Reenter");

        // Vaults can only be rolled during the settlement period
        uint256 blockTime = block.timestamp;
        require(vaultConfig.isInSettlement(blockTime), "In Settlement");

        // Must exit the entire current borrow position
        int256 assetCashCostToExitInternal = vaultConfig.exitVault(account, totalfCashPosition, minLendRate, blockTime);

        // Reenter the vault in the next term at the corresponding fCash value
        (
            int256 assetCashCollateralRequiredInternal,
            int256 assetCashToVaultInternal
        ) = vaultConfig.enterNextVault(vault, account, fCash, maxBorrowRate, blockTime);

        // If the costToExit can be covered by the amount borrowed, then the net amount will be
        // entered into the next vault. In this case the account is increasing their net vault
        // position:
        // (collateralRequired + cashToVault) - costToExit > 0
        //
        // If the costToExit cannot be covered by the amount borrowed, then some amount of vault
        // shares must be exited to cover the costToExit. In this case the account is decreasing
        // their net vault position:
        // (collateralRequired + cashToVault) - costToExit < 0
        //   In this situation, accounts can opt to sell some share of vault holdings to cover
        //   the the costs. For the remainder, we will transfer tokens from the account.
        //      - We first attempt to sell off vault holdings
        //      - If that is not sufficient then we attempt to transfer from the account
        int256 netAssetCashToVault = assetCashCollateralRequiredInternal
            .add(assetCashToVaultInternal)
            .sub(assetCashCostToExitInternal);

        // In the case of zero we don't do anything
        if (netAssetCashToVault > 0) {
            // Tell the vault that the account has re-entered the vault with some net position
            netAssetCashToVault = assetToken.transfer(vault, vaultConfig.borrowCurrencyId, netAssetCashToVault.neg());
            return ILeveredVault(vault).rollVaultPosition(account, assetCashToVaultExternal, vaultData);
        } else if (netAssetCashToVault < 0) {
            int256 assetCashRaisedExternal = ILeveredVault(vault).exitVault(account, vaultShareToExit);
            require(assetCashRaisedExternal >= 0);
            netAssetCashToVault = netAssetCashToVault.add(assetCashRaisedExternal);

            if (netAssetCashToVault < 0) {
                netAssetCashToVault = netAssetCashToVault.add(
                    assetToken.transfer(vault, vaultConfig.borrowCurrencyId, netAssetCashToVault.neg());
                );
                require(netAssetCashToVault == 0);
            }

            // TODO: is this logic correct?
            return ILeveredVault(vault).rollVaultPosition(account, 0, vaultData);
        }
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

        // The vault will return the total amount of shares available to settle. In the case of an
        // emergency stop out, this will be some positive amount. In the case of a settlement period
        // the vault will return some function of the shares available to settle to smooth out the
        // settlement period.
        // TODO: also make sure to provide a view method to this:
        // uint256 vaultSharesToSettle = ILeveredVault(vault).balanceAvailableToSettle();

        uint256 vaultTotalSupply = ILeveredVault(vault).totalSupplyForMaturity(
            vaultConfig.getCurrentMaturity(blockTime)
        );

        (
            uint256 vaultSharesSettled,
            int256 assetCashRaisedExternal,
        ) = ILeveredVault(vault).settleVault(vaultData);

        // Exit the portion of the total fCash borrowed in the vault. This method does not lend,
        // it just calculates the amount to deposit.
        int256 assetCashCostToExitInternal = vaultConfig.exitVaultGlobal(vault, vaultSharesSettled, vaultTotalSupply);

        if (assetCashRaisedExternal >= assetCashCostToExitInternal) {
            // We only transfer the cost to exit. All account fCash owed will decrease proportionally (since they own
            // shares of the total debt).
        } else {
            // There appears to be a shortfall. Immediately pause the vault.

            // If the total supply has been exited then we will go to trigger a redemption of nTokens
        }

        // TODO: pay the caller a fee for the transaction...
    }
}