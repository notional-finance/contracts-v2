// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultAccount,
    VaultState,
    PrimeRate,
    VaultConfig
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {VaultConfiguration} from "../../internal/vaults/VaultConfiguration.sol";
import {VaultAccountLib} from "../../internal/vaults/VaultAccount.sol";
import {VaultValuation} from "../../internal/vaults/VaultValuation.sol";
import {VaultStateLib, VaultState} from "../../internal/vaults/VaultState.sol";

import {ActionGuards} from "./ActionGuards.sol";
import {TradingAction} from "./TradingAction.sol";
import {IVaultAccountAction, IVaultAccountHealth} from "../../../interfaces/notional/IVaultController.sol";

contract VaultAccountAction is ActionGuards, IVaultAccountAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Settles a matured vault account by transforming it from an fCash maturity into
    /// a prime cash account. This method is not authenticated, anyone can settle a vault account
    /// without permission. Generally speaking, this action is economically equivalent no matter
    /// when it is called. In some edge conditions when the vault is holding prime cash, it is
    /// advantageous for the vault account to have this called sooner. All vault account actions
    /// will first settle the vault account before taking any further actions.
    /// @param account the address to settle
    /// @param vault the vault the account is in
    function settleVaultAccount(address account, address vault) external override nonReentrant {
        requireValidAccount(account);
        require(account != vault);

        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        
        // Require that the account settled, otherwise we may leave the account in an unintended
        // state in this method because we allow it to skip the min borrow check in the next line.
        (bool didSettle, bool didTransfer) = vaultAccount.settleVaultAccount(vaultConfig);
        require(didSettle, "No Settle");

        vaultAccount.accruePrimeCashFeesToDebt(vaultConfig);

        // Skip Min Borrow Check so that accounts can always be settled
        vaultAccount.setVaultAccount({vaultConfig: vaultConfig, checkMinBorrow: false, emitEvents: true});

        if (didTransfer) {
            // If the vault did a transfer (i.e. withdrew cash) we have to check their collateral ratio. There
            // is an edge condition where a vault with secondary borrows has an emergency exit. During that process
            // an account will be left some cash balance in both currencies. It may have excess cash in one and
            // insufficient cash in the other. A withdraw of the excess in one side will cause the vault account to
            // be insolvent if we do not run this check. If this scenario indeed does occur, the vault itself must
            // be upgraded in order to facilitate orderly exits for all of the accounts since they will be prevented
            // from settling.
            IVaultAccountHealth(address(this)).checkVaultAccountCollateralRatio(vault, account);
        }
    }

    /// @notice Borrows a specified amount of fCash in the vault's borrow currency and deposits it
    /// all plus the depositAmountExternal into the vault to mint strategy tokens.
    /// @param account the address that will enter the vault
    /// @param vault the vault to enter
    /// @param depositAmountExternal some amount of additional collateral in the borrowed currency
    /// to be transferred to vault
    /// @param maturity the maturity to borrow at
    /// @param borrowAmount amount to borrow, for fCash maturities this is the fCash amount. For pCash
    /// maturities this is the underlying borrowed.
    /// @param maxBorrowRate maximum interest rate to borrow at, only applies as a slippage limit for
    /// fCash maturities
    /// @param vaultData additional data to pass to the vault contract
    /// @return vaultSharesAdded the total vault shares tokens added to the maturity. Allows enterVault
    /// to be used by off-chain methods to get an accurate simulation of the strategy tokens minted.
    function enterVault(
        address account,
        address vault,
        uint256 depositAmountExternal,
        uint256 maturity,
        uint256 borrowAmount,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) external payable override nonReentrant returns (uint256 vaultSharesAdded) { 
        // Ensure that system level accounts cannot enter vaults
        requireValidAccount(account);
        require(account != vault);

        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ENTRY);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // Vaults cannot be entered if they are paused or matured
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED));
        require(block.timestamp < maturity);

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        vaultAccount.settleAccountOrAccruePrimeCashFees(vaultConfig);

        // Accounts can only call enter vault when establishing a new account or increasing an existing
        // position. Accounts that have matured fCash positions can increase their prime cash position.
        require(vaultAccount.maturity == 0 || vaultAccount.maturity == maturity); // dev: cannot enter with matured position

        // Deposits some amount of tokens into as margin for the vault. The tokens are first transferred into Notional
        // and then withdrawn as prime cash when entering the vault
        vaultConfig.depositMarginForVault(vaultAccount, depositAmountExternal);

        vaultSharesAdded = vaultAccount.borrowAndEnterVault(
            vaultConfig, maturity, borrowAmount, maxBorrowRate, vaultData, 0
        );

        IVaultAccountHealth(address(this)).checkVaultAccountCollateralRatio(vault, account);
    }

    /// @notice Re-enters the vault at a different maturity. The account's existing borrow position will be closed
    /// and a new borrow position at the specified maturity will be opened. Strategy token holdings will transfer
    /// to the new maturity. Accounts can roll to longer or shorter dated maturities.
    /// @param account the address that will reenter the vault
    /// @param vault the vault to reenter
    /// @param newBorrowAmount amount of fCash to borrow in the next maturity
    /// @param maturity new maturity to borrow at
    /// @param depositAmountExternal amount to deposit into the new maturity
    /// @param minLendRate slippage protection for repaying debts
    /// @param maxBorrowRate slippage protection for new borrow position
    /// @return vaultSharesAdded the total strategy tokens added to the maturity, including any tokens
    /// rolled from the previous maturity. Allows rollVaultPosition to be used by off-chain methods to get
    /// an accurate simulation of the strategy tokens minted.
    function rollVaultPosition(
        address account,
        address vault,
        uint256 newBorrowAmount,
        uint256 maturity,
        uint256 depositAmountExternal,
        uint32 minLendRate,
        uint32 maxBorrowRate,
        bytes calldata enterVaultData
    ) external payable override nonReentrant returns (uint256 vaultSharesAdded) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_ROLL);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        // If the vault account has matured, this will return a vault account in the prime cash
        // maturity. The vault account may have some temporary cash balance that will be applied
        // to lending or borrowing.
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        vaultAccount.settleAccountOrAccruePrimeCashFees(vaultConfig);

        // Cannot roll unless all of these requirements are met
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED));
        require(vaultConfig.getFlag(VaultConfiguration.ALLOW_ROLL_POSITION));
        // Must borrow into the new maturity, otherwise account should exit
        require(newBorrowAmount > 0);
        // Cannot roll into the existing maturity, after settlement this will be the prime cash maturity
        require(vaultAccount.maturity != maturity);
        require(block.timestamp < maturity); // dev: cannot roll to matured

        // VaultState must be loaded after settleAccountOrAccruePrimeCashFees
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig, vaultAccount.maturity);
        // Exit the maturity pool by removing all the vault shares.
        vaultSharesAdded = vaultAccount.vaultShares;
        vaultState.exitMaturity(vaultAccount, vaultConfig, vaultAccount.vaultShares);

        // Exit the vault first and debit the temporary cash balance with the cost to exit
        vaultAccount.lendToExitVault(
            vaultConfig,
            vaultState,
            vaultAccount.accountDebtUnderlying.neg(), // must fully exit the fCash position
            minLendRate,
            block.timestamp
        );

        // This should never be the case for a healthy vault account due to the mechanics of exiting the vault
        // above but we check it for safety here.
        require(vaultAccount.accountDebtUnderlying == 0);
        vaultState.setVaultState(vaultConfig);

        // Takes a deposit from the user as repayment for the lending, allows an account to roll their position
        // even if they are close to the max borrow capacity.
        vaultConfig.depositMarginForVault(vaultAccount, depositAmountExternal);

        // Enters the vault at the longer dated maturity. The account is required to borrow at this
        // point due  to the requirement earlier in this method, they cannot enter the maturity
        // with below minAccountBorrowSize
        vaultSharesAdded = vaultAccount.borrowAndEnterVault(
            vaultConfig,
            maturity, // This is the new maturity to enter
            newBorrowAmount,
            maxBorrowRate,
            enterVaultData,
            vaultSharesAdded
        );

        // emit VaultRollPosition(vault, account, maturity, newBorrowAmount);
        IVaultAccountHealth(address(this)).checkVaultAccountCollateralRatio(vault, account);
    }

    /// @notice Allows an account to withdraw their position from the vault at any time. Will
    /// redeem some number of vault shares to the borrow currency and close the borrow position by
    /// lending. Any shortfall in cash from lending will be transferred from the account, any excess
    /// profits will be transferred to the account.
    /// @param account the address that will exit the vault
    /// @param vault the vault to enter
    /// @param receiver the address that will receive profits
    /// @param vaultSharesToRedeem amount of vault tokens to exit, only relevant when exiting pre-maturity
    /// @param lendAmount amount of fCash to lend if fixed, amount of underlying to lend if in pCash
    /// @param minLendRate the minimum rate to lend at
    /// @param exitVaultData passed to the vault during exit
    /// @return underlyingToReceiver amount of underlying tokens returned to the receiver on exit
    function exitVault(
        address account,
        address vault,
        address receiver,
        uint256 vaultSharesToRedeem,
        uint256 lendAmount,
        uint32 minLendRate,
        bytes calldata exitVaultData
    ) external payable override nonReentrant returns (uint256 underlyingToReceiver) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        vaultConfig.authorizeCaller(account, VaultConfiguration.ONLY_VAULT_EXIT);

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        require(vaultAccount.lastUpdateBlockTime + Constants.VAULT_ACCOUNT_MIN_TIME <= block.timestamp);

        // Do this after the check above to ensure that the lastUpdateBlockTime is enforced
        vaultAccount.settleAccountOrAccruePrimeCashFees(vaultConfig);

        // Vault state must be loaded after settleAccountOrAccruePrimeCashFees
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig, vaultAccount.maturity);
        if (vaultAccount.maturity == Constants.PRIME_CASH_VAULT_MATURITY && lendAmount == type(uint256).max) {
            // Since prime cash values are rebasing it is difficult to calculate a full repayment off chain. If
            // the vault account is in the prime cash maturity the uint256 max value signifies a full repayment
            lendAmount = vaultAccount.accountDebtUnderlying.neg().toUint();
        }

        // Puts a negative cash balance on the vault's temporary cash balance
        vaultAccount.lendToExitVault(
            vaultConfig, vaultState, lendAmount.toInt(), minLendRate, block.timestamp
        );
        vaultState.exitMaturity(vaultAccount, vaultConfig, vaultSharesToRedeem);

        // If insufficient strategy tokens are redeemed (or if it is set to zero), then
        // redeem with debt repayment will recover the repayment from the account's wallet
        // directly.
        underlyingToReceiver = underlyingToReceiver.add(vaultConfig.redeemWithDebtRepayment(
            vaultAccount, receiver, vaultSharesToRedeem, exitVaultData
        ));

        // Set the vault state after redemption completes
        vaultState.setVaultState(vaultConfig);

        if (vaultAccount.accountDebtUnderlying == 0 && vaultAccount.vaultShares == 0) {
            // If the account has no position in the vault at this point, set the maturity to zero as well
            vaultAccount.maturity = 0;
        }
        vaultAccount.setVaultAccount({vaultConfig: vaultConfig, checkMinBorrow: true, emitEvents: true});

        // It's possible that the user redeems more vault shares than they lend (it is not always the case
        // that they will be increasing their collateral ratio here, so we check that this is the case). No
        // need to check if the account has exited in full (maturity == 0).
        if (vaultAccount.maturity != 0) {
            IVaultAccountHealth(address(this)).checkVaultAccountCollateralRatio(vault, account);
        }
    }

    function getLibInfo() external pure returns (address) {
        return address(TradingAction);
    }
}
