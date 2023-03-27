// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultAccount,
    VaultConfig,
    VaultState,
    VaultStateStorage,
    PrimeRate,
    PrimeCashFactorsStorage,
    Token
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {FloatingPoint} from "../../math/FloatingPoint.sol";

import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {TokenHandler} from "../balances/TokenHandler.sol";

import {VaultConfiguration} from "./VaultConfiguration.sol";
import {VaultAccountLib} from "./VaultAccount.sol";
import {VaultValuation} from "./VaultValuation.sol";
import {VaultSecondaryBorrow} from "./VaultSecondaryBorrow.sol";

import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

/// @notice VaultState holds a combination of asset cash and strategy tokens on behalf of the
/// vault accounts. When accounts enter or exit the pool they receive vault shares corresponding to
/// at the ratio of asset cash to strategy tokens in the corresponding maturity. A maturity may hold
/// asset cash during a risk-off event or as it unwinds to repay its debt at maturity. A VaultState
/// will also hold settlement values after a vault is matured.
library VaultStateLib {
    using PrimeRateLib for PrimeRate;
    using TokenHandler for Token;
    using VaultConfiguration for VaultConfig;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    function readDebtStorageToUnderlying(
        PrimeRate memory pr,
        uint256 maturity,
        uint80 debtStored
    ) internal pure returns (int256 debtUnderlying) {
        return maturity == Constants.PRIME_CASH_VAULT_MATURITY ?
            pr.convertDebtStorageToUnderlying(-int256(uint256(debtStored))) :
            -int256(uint256(debtStored));
    }

    function calculateDebtStorage(
        PrimeRate memory pr,
        uint256 maturity,
        int256 debtUnderlying
    ) internal pure returns (int256 debtStored) {
        return maturity == Constants.PRIME_CASH_VAULT_MATURITY ?
            pr.convertUnderlyingToDebtStorage(debtUnderlying) :
            debtUnderlying;
    }

    /// @notice Convenience method for getting the current prime debt in underlying terms
    function getCurrentPrimeDebt(
        VaultConfig memory vaultConfig,
        PrimeRate memory pr,
        uint16 currencyId
    ) internal view returns (int256 totalPrimeDebtInUnderlying) {
        VaultStateStorage storage s;
        if (currencyId == vaultConfig.borrowCurrencyId) {
            s = LibStorage.getVaultState()[vaultConfig.vault][Constants.PRIME_CASH_VAULT_MATURITY];
        } else {
            s = LibStorage.getVaultSecondaryBorrow()[vaultConfig.vault][Constants.PRIME_CASH_VAULT_MATURITY][currencyId];
        }

        totalPrimeDebtInUnderlying = readDebtStorageToUnderlying(
            pr, Constants.PRIME_CASH_VAULT_MATURITY, s.totalDebt
        );
    }

    function getVaultState(
        VaultConfig memory vaultConfig,
        uint256 maturity
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][maturity];

        vaultState.maturity = maturity;
        vaultState.isSettled = s.isSettled;
        vaultState.totalVaultShares = s.totalVaultShares;
        vaultState.totalDebtUnderlying = readDebtStorageToUnderlying(
            vaultConfig.primeRate, maturity, s.totalDebt
        );
    }

    /// @notice Sets a vault state before it has been settled
    function setVaultState(VaultState memory vaultState, VaultConfig memory vaultConfig) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][vaultState.maturity];
        s.totalVaultShares = vaultState.totalVaultShares.toUint80();
        s.isSettled = vaultState.isSettled;

        setTotalDebtStorage(
            s,
            vaultConfig.primeRate,
            vaultConfig,
            vaultConfig.borrowCurrencyId,
            vaultState.maturity,
            vaultState.totalDebtUnderlying,
            vaultState.isSettled
        );
    }

    function setTotalDebtStorage(
        VaultStateStorage storage s,
        PrimeRate memory pr,
        VaultConfig memory vaultConfig,
        uint16 currencyId,
        uint256 maturity,
        int256 totalDebtUnderlying,
        bool isSettled
    ) internal {
        int256 previousStoredDebtBalance = -int256(uint256(s.totalDebt));
        int256 newStoredDebtBalance = calculateDebtStorage(pr, maturity, totalDebtUnderlying);
        s.totalDebt = newStoredDebtBalance.neg().toUint().toUint80();
        // negChange returns the net change in negative balances. In leveraged vaults, debt balances
        // are always zero or negative. If more debt is accrued, this will return a negative number.
        // If debt is reduced, this will return a positive number.
        int256 netDebtChange = previousStoredDebtBalance.negChange(newStoredDebtBalance);

        int256 totalPrimeDebt;
        // Need to update either the Prime Cash or fCash debt counters on storage.
        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // The vault will hold the prime debt from an external event emission viewpoint
            pr.updateTotalPrimeDebt(vaultConfig.vault, currencyId, netDebtChange);
            totalPrimeDebt = totalDebtUnderlying;
        } else if (!isSettled) {
            // Update total fCash debt outstanding if vault has not been settled yet
            PrimeCashExchangeRate.updateTotalfCashDebtOutstanding(
                vaultConfig.vault, currencyId, maturity, previousStoredDebtBalance, newStoredDebtBalance
            );
            VaultConfiguration.updatefCashBorrowCapacity(vaultConfig.vault, currencyId, netDebtChange.neg());
            totalPrimeDebt = VaultStateLib.getCurrentPrimeDebt(vaultConfig, pr, currencyId);
        }

        if (netDebtChange > 0 && !isSettled) {
            // Only check borrow capacity if we are increasing the debt position (i.e. netDebtChange
            // is negative) and the vault is not yet settled (only the case with fCash).
            VaultConfiguration.checkBorrowCapacity(vaultConfig.vault, currencyId, totalPrimeDebt);
        }
    }

    function _increaseVaultShares(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 vaultSharesMinted
    ) private {
        require(vaultAccount.maturity == vaultState.maturity);
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][vaultState.maturity];

        // Update the values in memory
        vaultState.totalVaultShares = vaultState.totalVaultShares.add(vaultSharesMinted);
        vaultAccount.vaultShares = vaultAccount.vaultShares.add(vaultSharesMinted);

        // Update the global value in storage
        s.totalVaultShares = vaultState.totalVaultShares.toUint80();
    }

    /// @notice Exits a maturity for an account given the shares to redeem.
    /// @param vaultState vault state
    /// @param vaultAccount will use the maturity on the vault account to choose which pool to exit
    /// @param vaultSharesToRedeem amount of shares to redeem
    function exitMaturity(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 vaultSharesToRedeem
    ) internal {
        require(vaultAccount.maturity == vaultState.maturity);
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][vaultState.maturity];

        // Update the values in memory
        vaultState.totalVaultShares = vaultState.totalVaultShares.sub(vaultSharesToRedeem);
        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToRedeem);

        // Update the global value in storage
        s.totalVaultShares = vaultState.totalVaultShares.toUint80();
    }

    /// @notice Enters a maturity pool (including depositing cash and minting vault shares).
    /// @param vaultState vault state for the maturity we are entering
    /// @param vaultAccount will update maturity and vault shares and reduce tempCashBalance to zero
    /// @param vaultConfig vault config
    /// @param vaultShareDeposit any existing amount of vault shares to deposit from settlement or during a roll vault position
    /// @param vaultData calldata to pass to the vault
    function enterMaturity(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 vaultShareDeposit,
        bytes calldata vaultData
    ) internal returns (uint256 vaultSharesAdded) {
        // An account cannot enter a vault with a negative temp cash balance. This can happen during roll vault where
        // an insufficient amount is borrowed to repay its previous maturity debt.
        require(vaultAccount.tempCashBalance >= 0);

        if (vaultAccount.maturity != vaultState.maturity) {
            // This condition can occur in three scenarios, in all of these scenarios it cannot have any claim on the
            // previous maturity's assets:
            //  - when an account is newly established
            //  - when an account is entering a maturity after settlement
            //  - when an account is rolling from a different maturity
            require(vaultAccount.vaultShares == 0);
            vaultAccount.maturity = vaultState.maturity;
        } else {
            require(vaultAccount.maturity == vaultState.maturity);
        }

        // If an account that is rolling their position forward, then we set the vault share
        // deposit before we call deposit so the vault will see the additional shares if it calls
        // back into Notional.
        _increaseVaultShares(vaultState, vaultAccount, vaultConfig, vaultShareDeposit);

        uint256 vaultSharesMinted = vaultConfig.deposit(
            vaultAccount.account, vaultAccount.tempCashBalance, vaultState.maturity, vaultData
        );

        // Clear the cash balance after the deposit
        vaultAccount.tempCashBalance = 0;

        // Update the vault state again for the new tokens that were minted inside deposit.
        _increaseVaultShares(vaultState, vaultAccount, vaultConfig, vaultSharesMinted);

        // Return the total vault shares added to the maturity
        vaultSharesAdded = vaultShareDeposit.add(vaultSharesMinted);
        setVaultState(vaultState, vaultConfig);
    }

    function settleVaultSharesToPrimeVault(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultStateStorage storage primeVaultState
    ) internal {
        uint256 vaultSharesToPrimeMaturity;
        if (vaultConfig.getFlag(VaultConfiguration.VAULT_MUST_SETTLE)) {
            // Some vaults must settle their vault shares explicitly if they are not fungible between
            // maturities. If this is the case, then the vault must convert the vault shares prime maturity
            // vault share in order for individual vault accounts to settle their individual positions. One
            // example of this is a vault that holds fCash as its strategy token.
            vaultSharesToPrimeMaturity = IStrategyVault(vaultConfig.vault).convertVaultSharesToPrimeMaturity(
                vaultAccount.account,
                vaultAccount.vaultShares,
                vaultState.maturity
            );
        } else {
            vaultSharesToPrimeMaturity = vaultAccount.vaultShares;
        }

        // Clears the account's vault shares in memory
        exitMaturity(vaultState, vaultAccount, vaultConfig, vaultAccount.vaultShares);
        
        // Set the account's new prime vault shares directly
        vaultAccount.vaultShares = vaultSharesToPrimeMaturity;

        // Update prime vault shares directly
        primeVaultState.totalVaultShares = uint256(primeVaultState.totalVaultShares)
            .add(vaultSharesToPrimeMaturity).toUint80();
    }

    function settleTotalDebtToPrimeCash(
        VaultStateStorage storage primeVaultState,
        address vault,
        uint16 currencyId,
        uint256 maturity,
        int256 totalfCashDebt
    ) internal {
        // Set the prime cash vault state manually because we should not be updating
        // the totalPrimeDebt during this method (that has already happened within
        // the global settlement process). This will emit events that burn the fCash debt
        // on the vault and transfer prime debt from the settlement reserve.
        int256 settledPrimeDebtValue = PrimeRateLib.convertSettledfCashInVault(
            currencyId, maturity, totalfCashDebt, vault
        );

        // We know for sure that the vault has a minimum of "settledPrimeDebtValue" as a result of the
        // "totalfCashDebt" settlement. However, some vault accounts may be holding "vault cash" as a
        // result of a liquidation event.  We cannot repay those debts globally because this cash is held
        // in accounts individually. This method only updates the vault state to ensure that borrow capacity
        // is properly enforced.  In the absence of any "vault cash", this value represents the total
        // amount of prime debt owed by all the vault accounts in this maturity.
        int256 totalPrimeDebt = int256(uint256(primeVaultState.totalDebt));
        int256 newTotalDebt = totalPrimeDebt.sub(settledPrimeDebtValue);
        // Set the total debt to the storage value
        primeVaultState.totalDebt = newTotalDebt.toUint().toUint80();

        // Reduce the total fCash borrow capacity
        VaultConfiguration.updatefCashBorrowCapacity(vault, currencyId, totalfCashDebt.neg());
    }
}