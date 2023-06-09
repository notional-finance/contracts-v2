// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultConfig,
    VaultAccount,
    VaultAccountStorage,
    VaultState,
    VaultStateStorage,
    VaultAccountSecondaryDebtShareStorage,
    PrimeRate
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {Emitter} from "../Emitter.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {TokenHandler} from "../balances/TokenHandler.sol";

import {VaultSecondaryBorrow} from "./VaultSecondaryBorrow.sol";
import {VaultConfiguration} from "./VaultConfiguration.sol";
import {VaultStateLib} from "./VaultState.sol";

import {IVaultAction} from "../../../interfaces/notional/IVaultController.sol";

library VaultAccountLib {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Returns a single account's vault position
    function getVaultAccount(
        address account, VaultConfig memory vaultConfig
    ) internal view returns (VaultAccount memory vaultAccount) {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage.getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultConfig.vault];

        vaultAccount.maturity = s.maturity;
        vaultAccount.vaultShares = s.vaultShares;
        vaultAccount.account = account;
        // Read any temporary cash balance onto the stack to be applied
        vaultAccount.tempCashBalance = int256(uint256(s.primaryCash));
        vaultAccount.lastUpdateBlockTime = s.lastUpdateBlockTime;

        vaultAccount.accountDebtUnderlying = VaultStateLib.readDebtStorageToUnderlying(
            vaultConfig.primeRate, vaultAccount.maturity, s.accountDebt
        );
    }

    /// @notice Called when a vault account is liquidated and cash is deposited into its account and held
    /// as collateral against fCash
    function setVaultAccountForLiquidation(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 currencyIndex,
        int256 netCashBalanceChange,
        bool checkMinBorrow
    ) internal {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[vaultAccount.account][vaultConfig.vault];
        
        if (currencyIndex == 0) {
            s.primaryCash = int256(uint256(s.primaryCash)).add(netCashBalanceChange).toUint().toUint80();
        } else if (currencyIndex == 1) {
            s.secondaryCashOne = int256(uint256(s.secondaryCashOne)).add(netCashBalanceChange).toUint().toUint80();
        } else if (currencyIndex == 2) {
            s.secondaryCashTwo = int256(uint256(s.secondaryCashTwo)).add(netCashBalanceChange).toUint().toUint80();
        } else {
            // This should never occur
            revert();
        }

        // Clear temp cash balance, it is not updated during liquidation
        vaultAccount.tempCashBalance = 0;

        // No events emitted
        _setVaultAccount(vaultAccount, vaultConfig, s, checkMinBorrow, false);
    }

    function setVaultAccountInSettlement(VaultAccount memory vaultAccount, VaultConfig memory vaultConfig) internal {
        int256 tempCashBalance = vaultAccount.tempCashBalance;
        vaultAccount.tempCashBalance = 0;

        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[vaultAccount.account][vaultConfig.vault];
        
        _setVaultAccount(vaultAccount, vaultConfig, s, true, true);

        // Allow vault accounts that settle to retain excess cash balances. This occurs after set vault account
        // so that event emission remains correct (since it relies on the prior stored value).
        if (tempCashBalance == 0) {
            s.primaryCash = 0;
        } else if (0 < tempCashBalance) {
            // No need to add to primary cash here, we just set it to the final value. _setVaultAccount will have minted a
            // burn of the vault cash in the prior maturity so this will mint vault cash in the prime maturity.
            s.primaryCash = tempCashBalance.toUint().toUint80();
            Emitter.emitVaultMintOrBurnCash(
                vaultAccount.account, vaultConfig.vault, vaultConfig.borrowCurrencyId, vaultAccount.maturity, tempCashBalance
            );
        }
    }

    /// @notice Sets a single account's vault position in storage
    function setVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        bool checkMinBorrow,
        bool emitEvents
    ) internal {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[vaultAccount.account][vaultConfig.vault];

        _setVaultAccount(vaultAccount, vaultConfig, s, checkMinBorrow, emitEvents);

        // Cash balances should never be preserved after a non-liquidation transaction,
        // during enter, exit, roll and settle any cash balances should be applied to
        // the transaction. These cash balances are only set after liquidation.
        s.primaryCash = 0;
        require(s.secondaryCashOne == 0 && s.secondaryCashTwo == 0); // dev: secondary cash
    }

    function _setVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultAccountStorage storage s,
        bool checkMinBorrow,
        bool emitEvents
    ) private {
        // The temporary cash balance must be cleared to zero by the end of the transaction
        require(vaultAccount.tempCashBalance == 0); // dev: cash balance not cleared
        // An account must maintain a minimum borrow size in order to enter the vault. If the account
        // wants to exit under the minimum borrow size it must fully exit so that we do not have dust
        // accounts that become insolvent.
        if (
            vaultAccount.accountDebtUnderlying.neg() < vaultConfig.minAccountBorrowSize &&
            // During local currency liquidation and settlement, the min borrow check is skipped
            checkMinBorrow
        ) {
            // NOTE: use 1 to represent the minimum amount of vault shares due to rounding in the
            // vaultSharesToLiquidator calculation
            require(vaultAccount.accountDebtUnderlying == 0 || vaultAccount.vaultShares <= 1, "Min Borrow");
        }

        if (vaultConfig.hasSecondaryBorrows()) {
            VaultAccountSecondaryDebtShareStorage storage _s = 
                LibStorage.getVaultAccountSecondaryDebtShare()[vaultAccount.account][vaultConfig.vault];
            uint256 secondaryMaturity = _s.maturity;
            require(vaultAccount.maturity == secondaryMaturity || secondaryMaturity == 0); // dev: invalid maturity

            // Sanity check to ensure that secondary maturity is set properly
            if (secondaryMaturity == 0) require(_s.accountDebtOne == 0 && _s.accountDebtTwo == 0);
        }

        uint256 newDebtStorageValue = VaultStateLib.calculateDebtStorage(
            vaultConfig.primeRate,
            vaultAccount.maturity,
            vaultAccount.accountDebtUnderlying
        ).neg().toUint();

        if (emitEvents) {
            // Liquidation will emit its own custom event instead of these
            Emitter.emitVaultAccountChanges(vaultAccount, vaultConfig, s, newDebtStorageValue);
        }

        s.vaultShares = vaultAccount.vaultShares.toUint80();
        s.maturity = vaultAccount.maturity.toUint40();
        s.lastUpdateBlockTime = vaultAccount.lastUpdateBlockTime.toUint32();
        s.accountDebt = newDebtStorageValue.toUint80();
    }

    /// @notice Updates the secondary cash held by the account, should only be updated in two places:
    ///   - During liquidation of a secondary borrow
    ///   - On vault exit when the secondary borrow currency is holding cash
    /// In setVaultAccount, a vault account cannot end up with a secondary cash balance at the end of a
    /// user initiated (non-liquidation) transaction. The vault must clearVaultAccountSecondaryCash during
    /// the redemption of strategy tokens.
    function setVaultAccountSecondaryCash(
        address account,
        address vault,
        int256 netSecondaryPrimeCashOne,
        int256 netSecondaryPrimeCashTwo
    ) internal {
        VaultAccountStorage storage s = LibStorage.getVaultAccount()[account][vault];
        s.secondaryCashOne = int256(uint256(s.secondaryCashOne)).add(netSecondaryPrimeCashOne).toUint().toUint80();
        s.secondaryCashTwo = int256(uint256(s.secondaryCashTwo)).add(netSecondaryPrimeCashTwo).toUint().toUint80();
    }

    function checkVaultAccountSecondaryCash(
        address account,
        address vault
    ) internal view {
        VaultAccountStorage storage s = LibStorage.getVaultAccount()[account][vault];
        require(s.secondaryCashOne == 0);
        require(s.secondaryCashTwo == 0);
    }
    
    function clearVaultAccountSecondaryCash(
        address account,
        address vault
    ) internal returns (int256 secondaryCashOne, int256 secondaryCashTwo) {
        VaultAccountStorage storage s = LibStorage.getVaultAccount()[account][vault];
        secondaryCashOne = int256(uint256(s.secondaryCashOne));
        secondaryCashTwo = int256(uint256(s.secondaryCashTwo));

        s.secondaryCashOne = 0;
        s.secondaryCashTwo = 0;
    }

    /// @notice Updates an account's fCash position and the current vault state at the same time. Also updates
    /// and checks the total borrow capacity
    /// @param vaultAccount vault account
    /// @param vaultState vault state matching the maturity
    /// @param netUnderlyingDebt underlying debt change to the account, (borrowing < 0, lending > 0)
    /// @param netPrimeCash amount of prime cash to charge or credit to the account, must be the oppositely
    /// signed compared to the netfCash sign
    function updateAccountDebt(
        VaultAccount memory vaultAccount,
        VaultState memory vaultState,
        int256 netUnderlyingDebt,
        int256 netPrimeCash
    ) internal pure {
        if (vaultAccount.maturity != vaultState.maturity) {
            // If borrowing across maturities, ensure that the account does not have any
            // debt in the old maturity remaining in their account.
            require(vaultAccount.accountDebtUnderlying == 0);
        }
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(netPrimeCash);

        // Update debt state on the account and the vault
        vaultAccount.accountDebtUnderlying = vaultAccount.accountDebtUnderlying.add(netUnderlyingDebt);
        require(vaultAccount.accountDebtUnderlying <= 0);
        vaultState.totalDebtUnderlying = vaultState.totalDebtUnderlying.add(netUnderlyingDebt);

        // Truncate dust balances towards zero
        if (0 < vaultState.totalDebtUnderlying && vaultState.totalDebtUnderlying < 10) vaultState.totalDebtUnderlying = 0;
        require(vaultState.totalDebtUnderlying <= 0);
    }


    /// @notice Enters into a vault position, borrowing from Notional if required.
    /// @param vaultAccount vault account entering the position
    /// @param vaultConfig vault configuration
    /// @param maturity maturity to enter into
    /// @param underlyingToBorrow a positive amount of underlying to borrow, will be converted to a negative
    /// amount inside the method
    /// @param maxBorrowRate the maximum annualized interest rate to borrow at, a zero signifies no
    /// slippage limit applied
    /// @param vaultData arbitrary data to be passed to the vault
    /// @param strategyTokenDeposit some amount of strategy tokens from a previous maturity that will
    /// be carried over into the current maturity
    /// @return vaultSharesAdded the total vault shares added to the maturity for the account,
    /// including any strategy tokens transferred during a roll or settle
    function borrowAndEnterVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 underlyingToBorrow,
        uint32 maxBorrowRate,
        bytes calldata vaultData,
        uint256 strategyTokenDeposit
    ) internal returns (uint256 vaultSharesAdded) {
        // The vault account can only be increasing their borrow position or not have one set. If they
        // are increasing their position they must be borrowing from the same maturity.
        require(vaultAccount.maturity == maturity || vaultAccount.accountDebtUnderlying == 0);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig, maturity);

        // Borrows fCash and puts the cash balance into the vault account's temporary cash balance
        if (underlyingToBorrow > 0) {
            _borrowIntoVault(
                vaultAccount,
                vaultConfig,
                vaultState,
                maturity,
                underlyingToBorrow.toInt().neg(),
                maxBorrowRate
            );
        } else if (maturity != Constants.PRIME_CASH_VAULT_MATURITY) {
            // Ensure that the maturity is a valid one if we are not borrowing (borrowing will fail)
            // against an invalid market.
            VaultConfiguration.checkValidMaturity(
                vaultConfig.borrowCurrencyId,
                maturity,
                vaultConfig.maxBorrowMarketIndex,
                block.timestamp
            );
        }

        // Sets the maturity on the vault account, deposits tokens into the vault, and updates the vault state 
        vaultSharesAdded = vaultState.enterMaturity(vaultAccount, vaultConfig, strategyTokenDeposit, vaultData);
        vaultAccount.lastUpdateBlockTime = block.timestamp;
        setVaultAccount({
            vaultAccount: vaultAccount, vaultConfig: vaultConfig, checkMinBorrow: true, emitEvents: true
        });
    }

    ///  @notice Borrows fCash to enter a vault and pays fees
    ///  @dev Updates vault fCash in storage, updates vaultAccount in memory
    ///  @param vaultAccount the account's position in the vault
    ///  @param vaultConfig configuration for the given vault
    ///  @param maturity the maturity to enter for the vault
    ///  @param underlyingToBorrow amount of underlying to borrow from the market, must be negative
    ///  @param maxBorrowRate maximum annualized rate to pay for the borrow
    function _borrowIntoVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity,
        int256 underlyingToBorrow,
        uint32 maxBorrowRate
    ) private {
        require(underlyingToBorrow < 0); // dev: fcash must be negative

        int256 primeCashBorrowed;
        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            primeCashBorrowed = vaultConfig.primeRate.convertFromUnderlying(underlyingToBorrow).neg();
        } else {
            // fCash fees are assessed on the amount of cash borrowed after execution of the trade
            primeCashBorrowed = VaultConfiguration.executeTrade(
                vaultConfig.borrowCurrencyId,
                vaultConfig.vault,
                maturity,
                underlyingToBorrow,
                maxBorrowRate,
                vaultConfig.maxBorrowMarketIndex,
                block.timestamp
            );
            // Only assess fCash fees here, Prime Cash fees are assessed in a separate method
            vaultConfig.assessVaultFees(vaultAccount, primeCashBorrowed, maturity, block.timestamp);
        }
        require(primeCashBorrowed > 0, "Borrow failed");

        updateAccountDebt(vaultAccount, vaultState, underlyingToBorrow, primeCashBorrowed);

        // Ensure that we are above the minimum borrow size. Accounts smaller than this are not profitable
        // to unwind if we need to liquidate.
        require(vaultConfig.minAccountBorrowSize <= vaultAccount.accountDebtUnderlying.neg(), "Min Borrow");
    }

    /// @notice Allows an account to exit a vault term prematurely by lending fCash.
    /// @param vaultAccount the account's position in the vault
    /// @param vaultConfig configuration for the given vault
    /// @param underlyingToRepay amount of underlying to lend must be positive and cannot
    /// lend more than the account's debt
    /// @param minLendRate minimum rate to lend at
    /// @param blockTime current block time
    function lendToExitVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 underlyingToRepay,
        uint32 minLendRate,
        uint256 blockTime
    ) internal {
        if (underlyingToRepay == 0) return;

        // Don't allow the vault to lend to positive
        require(vaultAccount.accountDebtUnderlying.add(underlyingToRepay) <= 0); // dev: positive debt
        
        // Check that the account is in an active vault
        require(blockTime < vaultAccount.maturity);
        
        // Returns the cost in prime cash terms as a negative value to lend an offsetting fCash position
        // so that the account can exit.
        int256 primeCashCostToLend;
        if (vaultAccount.maturity != Constants.PRIME_CASH_VAULT_MATURITY) {
            primeCashCostToLend = VaultConfiguration.executeTrade(
                vaultConfig.borrowCurrencyId,
                vaultConfig.vault,
                vaultAccount.maturity,
                underlyingToRepay,
                minLendRate,
                vaultConfig.maxBorrowMarketIndex,
                blockTime
            );
        }

        if (primeCashCostToLend == 0) {
            // There are two possibilities we reach this condition:
            //  - The account is borrowing in variable prime cash
            //  - Lending fCash has failed due to a lack of liquidity or negative interest rates. In this
            //    case just just net off the the prime cash balance and the account will forgo any money
            //    market interest accrued between now and maturity.
            //    If this scenario were to occur, it is most likely that interest rates are near zero suggesting
            //    that money market interest rates are also near zero (therefore the account is really not giving
            //    up much by forgoing money market interest).
            // NOTE: underlyingToRepay is positive here so primeCashToLend will be negative
            primeCashCostToLend = vaultConfig.primeRate.convertFromUnderlying(underlyingToRepay).neg();

            if (vaultAccount.maturity != Constants.PRIME_CASH_VAULT_MATURITY) {
                // Updates some state to track lending at zero for off chain accounting.
                PrimeCashExchangeRate.updateSettlementReserveForVaultsLendingAtZero(
                    vaultConfig.vault,
                    vaultConfig.borrowCurrencyId,
                    vaultAccount.maturity,
                    primeCashCostToLend.neg(),
                    underlyingToRepay
                );
            }
        }
        require(primeCashCostToLend <= 0);

        updateAccountDebt(vaultAccount, vaultState, underlyingToRepay, primeCashCostToLend);
        // NOTE: vault account and vault state are not set into storage in this method.
    }

    /// @notice Settles a vault account that has a position in a matured vault.
    /// @param vaultAccount the account's position in the vault
    /// @param vaultConfig configuration for the given vault
    /// @return didSettle true if the account did settle, false if it did not
    function settleVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig
    ) internal returns (bool didSettle) {
        // PRIME_CASH_VAULT_MATURITY will always be greater than block time and will not settle,
        // fCash settles exactly on block time. This exit will prevent any invalid maturities.
        if (vaultAccount.maturity == 0 || block.timestamp < vaultAccount.maturity) return false;
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig, vaultAccount.maturity);

        VaultStateStorage storage primeVaultState = LibStorage.getVaultState()
            [vaultConfig.vault][Constants.PRIME_CASH_VAULT_MATURITY];
        if (!vaultState.isSettled) {
            // Settles and updates the total prime debt so that max vault capacity
            // accounting is correct.
            VaultStateLib.settleTotalDebtToPrimeCash(
                primeVaultState,
                vaultConfig.vault,
                vaultConfig.borrowCurrencyId,
                vaultState.maturity,
                vaultState.totalDebtUnderlying
            );

            // This should only ever happen once, clear the total debt
            // underlying since it has transferred to the prime cash vault
            vaultState.totalDebtUnderlying = 0;
            vaultState.isSettled = true;
            // Set the fCash vault state to settled.
            vaultState.setVaultState(vaultConfig);
        }

        // Reduces vault shares in the fcash vault state in storage. Adds prime cash vault
        // shares to the account in memory.
        vaultState.settleVaultSharesToPrimeVault(vaultAccount, vaultConfig, primeVaultState);

        // Settle any secondary borrows if they exist into prime cash borrows.
        if (vaultConfig.hasSecondaryBorrows()) {
           IVaultAction(address(this)).settleSecondaryBorrowForAccount(
                vaultConfig.vault, vaultAccount.account
            );
        }

        int256 accountPrimeStorageValue = PrimeRateLib.convertSettledfCashInVault(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            vaultAccount.accountDebtUnderlying,
            address(0)
        );

        // Calculates the net settled cash if there is any temp cash balance that is net off
        // against the settled prime debt.
        (accountPrimeStorageValue, vaultAccount.tempCashBalance) = repayAccountPrimeDebtAtSettlement(
            vaultConfig.primeRate,
            primeVaultState,
            vaultConfig.borrowCurrencyId,
            vaultConfig.vault,
            vaultAccount.tempCashBalance,
            accountPrimeStorageValue
        );

        // Assess prime cash vault fees into the temp cash balance. The account has accrued prime cash
        // fees on the time since the fCash matured to the current block time. Setting lastUpdateBlockTime
        // to the fCash maturity, will calculate the fees accrued since that time.
        vaultAccount.lastUpdateBlockTime = vaultAccount.maturity;
        vaultAccount.maturity = Constants.PRIME_CASH_VAULT_MATURITY;
        vaultAccount.accountDebtUnderlying = vaultConfig.primeRate.convertDebtStorageToUnderlying(accountPrimeStorageValue);
        vaultConfig.assessVaultFees(
            vaultAccount,
            vaultConfig.primeRate.convertFromUnderlying(vaultAccount.accountDebtUnderlying).neg(),
            Constants.PRIME_CASH_VAULT_MATURITY,
            block.timestamp
        );

        return true;
    }

    /// @notice Called at the beginning of all vault actions (enterVault, exitVault, rollVaultPosition,
    /// deleverageVault) to ensure that certain actions occur prior to any other account actions.
    function settleAccountOrAccruePrimeCashFees(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig
    ) internal returns (bool didSettle) {
        // If the vault has matured, it will exit this settlement call in the prime cash maturity with
        // fees assessed up to the current time. Transfers may occur but they are not relevant in this
        // context since a collateral check will always be done on non-settlement methods.
        didSettle = settleVaultAccount(vaultAccount, vaultConfig);

        // If the account did not settle but is in the prime cash maturity, assess a fee.
        if (!didSettle && vaultAccount.maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // The prime cash fee is deducted from the tempCashBalance
            vaultConfig.assessVaultFees(
                vaultAccount,
                vaultConfig.primeRate.convertFromUnderlying(vaultAccount.accountDebtUnderlying).neg(),
                vaultAccount.maturity,
                block.timestamp
            );
        }
    }

    function accruePrimeCashFeesToDebtInLiquidation(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig
    ) internal returns (VaultState memory) {
        vaultConfig.assessVaultFees(
            vaultAccount,
            vaultConfig.primeRate.convertFromUnderlying(vaultAccount.accountDebtUnderlying).neg(),
            vaultAccount.maturity,
            block.timestamp
        );

        return accruePrimeCashFeesToDebt(vaultAccount, vaultConfig);
    }

    /// @notice Accrues prime cash fees directly to debt during settlement and liquidation
    function accruePrimeCashFeesToDebt(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig
    ) internal returns (VaultState memory vaultPrimeState) {
        require(vaultAccount.maturity == Constants.PRIME_CASH_VAULT_MATURITY);

        // During settle vault account, the prime cash fee is accrued to debt instead
        // of left in the tempCashBalance.
        vaultPrimeState = VaultStateLib.getVaultState(vaultConfig, Constants.PRIME_CASH_VAULT_MATURITY);

        // Fees and prime cash claims will be held in temp cash balance. If there is a positive cash balance then
        // it will not accrue to debt but remain in the cash balance.
        if (vaultAccount.tempCashBalance < 0) {
            updateAccountDebt(
                vaultAccount,
                vaultPrimeState,
                vaultConfig.primeRate.convertToUnderlying(vaultAccount.tempCashBalance),
                vaultAccount.tempCashBalance.neg()
            );
        }

        vaultPrimeState.setVaultState(vaultConfig);
    }

    function repayAccountPrimeDebtAtSettlement(
        PrimeRate memory pr,
        VaultStateStorage storage primeVaultState,
        uint16 currencyId,
        address vault,
        int256 accountPrimeCash,
        int256 accountPrimeStorageValue
    ) internal returns (int256 finalPrimeDebtStorageValue, int256 finalPrimeCash) {
        finalPrimeDebtStorageValue = accountPrimeStorageValue;
        
        if (accountPrimeCash > 0) {
            // netPrimeDebtRepaid is a negative number
            int256 netPrimeDebtRepaid = pr.convertUnderlyingToDebtStorage(
                pr.convertToUnderlying(accountPrimeCash).neg()
            );

            int256 netPrimeDebtChange;
            if (netPrimeDebtRepaid < accountPrimeStorageValue) {
                // If the net debt change is greater than the debt held by the account, then only
                // decrease the total prime debt by what is held by the account. The residual amount
                // will be refunded to the account via a direct transfer.
                netPrimeDebtChange = accountPrimeStorageValue;
                finalPrimeDebtStorageValue = 0;

                finalPrimeCash = pr.convertFromUnderlying(
                    // convertDebtStorageToUnderlying requires the input to be negative, therefore we have
                    // to do the subtraction and negation in this manner.
                    pr.convertDebtStorageToUnderlying(netPrimeDebtRepaid.sub(accountPrimeStorageValue)).neg()
                );
            } else {
                // In this case, part of the account's debt is repaid.
                netPrimeDebtChange = netPrimeDebtRepaid;
                // finalPrimeDebtStorageValue is a positive number here
                finalPrimeDebtStorageValue = accountPrimeStorageValue.sub(netPrimeDebtRepaid);
                // finalPrimeCash will be returned as zero here
            }

            // Updates the global prime debt figure and events are emitted via the vault.
            pr.updateTotalPrimeDebt(vault, currencyId, netPrimeDebtChange);

            // Updates the state on the prime vault storage directly.
            int256 totalPrimeDebt = int256(uint256(primeVaultState.totalDebt));
            int256 newTotalDebt = totalPrimeDebt.add(netPrimeDebtChange);
            // Set the total debt to the storage value
            primeVaultState.totalDebt = newTotalDebt.toUint().toUint80();
        }
    }
}
