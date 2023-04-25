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
    ETHRate,
    PrimeRate
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {Emitter} from "../Emitter.sol";
import {ExchangeRate} from "../valuation/ExchangeRate.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";

import {VaultConfiguration} from "./VaultConfiguration.sol";
import {VaultStateLib} from "./VaultState.sol";
import {VaultAccountLib} from "./VaultAccount.sol";
import {VaultValuation} from "./VaultValuation.sol";

/// @notice Handles all the logic related to secondary borrow currencies
library VaultSecondaryBorrow {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using PrimeRateLib for PrimeRate;
    using VaultConfiguration for VaultConfig;

    /// @notice Emitted when a vault executes a secondary borrow
    event VaultSecondaryTransaction(
        address indexed vault,
        address indexed account,
        uint16 indexed currencyId,
        uint256 maturity,
        int256 netUnderlyingDebt,
        int256 netPrimeSupply
    );

    struct SecondaryExchangeRates {
        int256 rateDecimals;
        int256 exchangeRateOne;
        int256 exchangeRateTwo;
    }

    struct ExcessVaultCashFactors {
        uint16 excessCashCurrencyId;
        uint16 debtCurrencyId;
        PrimeRate excessCashPR;
        PrimeRate debtPR;
        int256 exchangeRate;
        int256 rateDecimals;
    }

    /**** Secondary Borrow Getters ****/

    /// @notice Returns prime rates for secondary borrows
    function getSecondaryPrimeRateStateful(VaultConfig memory vaultConfig) internal returns (PrimeRate[2] memory pr) {
        if (vaultConfig.secondaryBorrowCurrencies[0] != 0)
            pr[0] = PrimeRateLib.buildPrimeRateStateful(vaultConfig.secondaryBorrowCurrencies[0]);
        if (vaultConfig.secondaryBorrowCurrencies[1] != 0)
            pr[1] = PrimeRateLib.buildPrimeRateStateful(vaultConfig.secondaryBorrowCurrencies[1]);
    }

    /// @notice Returns prime rates for secondary borrows
    function getSecondaryPrimeRateView(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal view returns (PrimeRate[2] memory pr) {
        if (vaultConfig.secondaryBorrowCurrencies[0] != 0)
            (pr[0], /* */) = PrimeCashExchangeRate.getPrimeCashRateView(vaultConfig.secondaryBorrowCurrencies[0], blockTime);
        if (vaultConfig.secondaryBorrowCurrencies[1] != 0)
            (pr[1], /* */) = PrimeCashExchangeRate.getPrimeCashRateView(vaultConfig.secondaryBorrowCurrencies[1], blockTime);
    }

    /// @notice Returns exchange rates back to the primary for secondary borrows
    function getExchangeRates(
        VaultConfig memory vaultConfig
    ) internal view returns (SecondaryExchangeRates memory er) {
        ETHRate memory primaryER = ExchangeRate.buildExchangeRate(vaultConfig.borrowCurrencyId);
        er.rateDecimals = primaryER.rateDecimals;

        if (vaultConfig.secondaryBorrowCurrencies[0] != 0){
            er.exchangeRateOne = ExchangeRate.exchangeRate(
                primaryER, 
                ExchangeRate.buildExchangeRate(vaultConfig.secondaryBorrowCurrencies[0])
            );
        }

        if (vaultConfig.secondaryBorrowCurrencies[1] != 0){
            er.exchangeRateTwo = ExchangeRate.exchangeRate(
                primaryER, 
                ExchangeRate.buildExchangeRate(vaultConfig.secondaryBorrowCurrencies[1])
            );
        }
    }

    function getLiquidateExcessCashFactors(
        VaultConfig memory vaultConfig,
        PrimeRate[2] memory primeRates,
        uint256 excessCashIndex,
        uint256 debtIndex
    ) internal view returns (ExcessVaultCashFactors memory f) {
        if (excessCashIndex == 0) {
            f.excessCashCurrencyId = vaultConfig.borrowCurrencyId;
            f.excessCashPR = vaultConfig.primeRate;
        } else {
            f.excessCashCurrencyId = vaultConfig.secondaryBorrowCurrencies[excessCashIndex - 1];
            f.excessCashPR = primeRates[excessCashIndex - 1];
        }

        if (debtIndex == 0) {
            f.debtCurrencyId = vaultConfig.borrowCurrencyId;
            f.debtPR = vaultConfig.primeRate;
        } else {
            f.debtCurrencyId = vaultConfig.secondaryBorrowCurrencies[debtIndex - 1];
            f.debtPR = primeRates[debtIndex - 1];
        }

        ETHRate memory baseER = ExchangeRate.buildExchangeRate(f.excessCashCurrencyId);
        ETHRate memory quoteER = ExchangeRate.buildExchangeRate(f.debtCurrencyId);
        f.exchangeRate = ExchangeRate.exchangeRate(baseER, quoteER);
        f.rateDecimals = baseER.rateDecimals;
    }

    /**** Secondary Borrow Debt ****/

    function getSecondaryBorrowCollateralFactors(
        VaultConfig memory vaultConfig,
        PrimeRate[2] memory primeRates,
        VaultState memory vaultState,
        address account
    ) internal view returns (
        int256 secondaryDebtInPrimary,
        int256 excessCashInPrimary,
        VaultSecondaryBorrow.SecondaryExchangeRates memory er,
        int256 debtOutstandingOne,
        int256 debtOutstandingTwo
    ) {
        er = getExchangeRates(vaultConfig);
        (debtOutstandingOne, debtOutstandingTwo, secondaryDebtInPrimary, excessCashInPrimary) = _getSecondaryAccountDebtsInPrimary(
            vaultConfig, primeRates, er, account, vaultState.maturity
        );
    }

    function getAccountSecondaryDebt(
        VaultConfig memory vaultConfig,
        address account,
        PrimeRate[2] memory pr
    ) internal view returns (uint256 maturity, int256 accountDebtOne, int256 accountDebtTwo) {
        VaultAccountSecondaryDebtShareStorage storage s = 
            LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];

        maturity = s.maturity;
        accountDebtOne = VaultStateLib.readDebtStorageToUnderlying(pr[0], maturity, s.accountDebtOne);
        accountDebtTwo = VaultStateLib.readDebtStorageToUnderlying(pr[1], maturity, s.accountDebtTwo);
    }

    function getSecondaryCashHeld(
        address account,
        address vault
    ) internal view returns (int256 secondaryCashOne, int256 secondaryCashTwo) {
        VaultAccountStorage storage a = LibStorage.getVaultAccount()[account][vault];
        secondaryCashOne = int256(uint256(a.secondaryCashOne));
        secondaryCashTwo = int256(uint256(a.secondaryCashTwo));
    }

    /// @notice Converts any two given secondary cash balances to primary valuation
    function _convertSecondaryUnderlyingToPrimary(
        SecondaryExchangeRates memory er,
        int256 secondaryUnderlyingOne,
        int256 secondaryUnderlyingTwo
    ) private pure returns (int256 totalDebtInPrimary, int256 totalExcessCashInPrimary) {
        if (secondaryUnderlyingOne < 0) {
            totalDebtInPrimary = secondaryUnderlyingOne.mul(er.rateDecimals).div(er.exchangeRateOne);
        } else {
            totalExcessCashInPrimary = secondaryUnderlyingOne.mul(er.rateDecimals).div(er.exchangeRateOne);
        }

        if (secondaryUnderlyingTwo < 0) {
            totalDebtInPrimary = totalDebtInPrimary.add(
                secondaryUnderlyingTwo.mul(er.rateDecimals).div(er.exchangeRateTwo)
            );
        } else {
            totalExcessCashInPrimary = totalExcessCashInPrimary.add(
                secondaryUnderlyingTwo.mul(er.rateDecimals).div(er.exchangeRateTwo)
            );
        }
    }

    function _getSecondaryAccountDebtsInPrimary(
        VaultConfig memory vaultConfig,
        PrimeRate[2] memory primeRates,
        SecondaryExchangeRates memory er,
        address account,
        uint256 maturity
    ) private view returns (
        int256 debtOutstandingOne,
        int256 debtOutstandingTwo,
        int256 totalDebtOutstandingInPrimary,
        int256 totalExcessCashInPrimary
    ) {
        (int256 secondaryCashOne, int256 secondaryCashTwo) = getSecondaryCashHeld(
            account, vaultConfig.vault
        );
        (/* */, debtOutstandingOne, debtOutstandingTwo) = getAccountSecondaryDebt(
            vaultConfig, account, primeRates
        );

        bool enableDiscount = vaultConfig.getFlag(VaultConfiguration.ENABLE_FCASH_DISCOUNT);
        if (vaultConfig.secondaryBorrowCurrencies[0] != 0) {
            debtOutstandingOne = VaultValuation.getPresentValue(
                primeRates[0],
                vaultConfig.secondaryBorrowCurrencies[0],
                maturity,
                debtOutstandingOne,
                enableDiscount
            ).add(primeRates[0].convertToUnderlying(secondaryCashOne));
        }

        if (vaultConfig.secondaryBorrowCurrencies[1] != 0) {
            debtOutstandingTwo = VaultValuation.getPresentValue(
                primeRates[1],
                vaultConfig.secondaryBorrowCurrencies[1],
                maturity,
                debtOutstandingTwo,
                enableDiscount
            ).add(primeRates[1].convertToUnderlying(secondaryCashTwo));
        }

        // Debt outstanding is reported in underlying denomination
        (totalDebtOutstandingInPrimary, totalExcessCashInPrimary) = _convertSecondaryUnderlyingToPrimary(
            er, debtOutstandingOne, debtOutstandingTwo
        );
    }
        
    /**** Secondary Borrow Trade Execution ****/

    /// @notice Executes a secondary borrow transaction
    /// @param vaultConfig vault config
    /// @param account address of account executing the secondary borrow (this may be the vault itself)
    /// @param maturity the maturity of the fCash
    /// @param netUnderlyingDebtOne net amount of debt for the first currency
    /// @param netUnderlyingDebtTwo net amount of debt for the second currency
    /// @param slippageLimits maximum annualized rate of fCash to borrow
    /// @return netPrimeCashOne net amount of prime cash to transfer
    /// @return netPrimeCashTwo net amount of prime cash to transfer
    function executeSecondary(
        VaultConfig memory vaultConfig,
        address account,
        uint256 maturity,
        int256 netUnderlyingDebtOne,
        int256 netUnderlyingDebtTwo,
        PrimeRate[2] memory pr,
        uint32[2] calldata slippageLimits
    ) internal returns (int256 netPrimeCashOne, int256 netPrimeCashTwo) {
        // Updates debt accounting, checks capacity and min borrow
        updateAccountSecondaryDebt(
            vaultConfig, account, maturity, netUnderlyingDebtOne, netUnderlyingDebtTwo, pr, true
        );

        if (netUnderlyingDebtOne != 0) {
            uint16 currencyId = vaultConfig.secondaryBorrowCurrencies[0];
            netPrimeCashOne = _executeSecondaryCurrencyTrade(
                vaultConfig, pr[0], currencyId, maturity, netUnderlyingDebtOne, slippageLimits[0] 
            );

            emit VaultSecondaryTransaction(
                vaultConfig.vault, account, currencyId, maturity, netUnderlyingDebtOne, netPrimeCashOne
            );
        }

        if (netUnderlyingDebtTwo != 0) {
            uint16 currencyId = vaultConfig.secondaryBorrowCurrencies[1];
            netPrimeCashTwo = _executeSecondaryCurrencyTrade(
                vaultConfig, pr[1], currencyId, maturity, netUnderlyingDebtTwo, slippageLimits[1]
            );

            emit VaultSecondaryTransaction(
                vaultConfig.vault, account, currencyId, maturity, netUnderlyingDebtTwo, netPrimeCashTwo
            );
        }

        // Clears any refunds on the vault account and applies them to the transaction
        (int256 primeCashRefundOne, int256 primeCashRefundTwo) = VaultAccountLib.clearVaultAccountSecondaryCash(
            account, vaultConfig.vault
        );

        // Burn previous refund if exists
        Emitter.emitVaultMintOrBurnCash(
            account, vaultConfig.vault, vaultConfig.secondaryBorrowCurrencies[0], maturity, primeCashRefundOne.neg()
        );
        Emitter.emitVaultMintOrBurnCash(
            account, vaultConfig.vault, vaultConfig.secondaryBorrowCurrencies[1], maturity, primeCashRefundTwo.neg()
        );
        netPrimeCashOne = netPrimeCashOne.add(primeCashRefundOne);
        netPrimeCashTwo = netPrimeCashTwo.add(primeCashRefundTwo);
    }

    function updateAccountSecondaryDebt(
        VaultConfig memory vaultConfig,
        address account,
        uint256 maturity,
        int256 netUnderlyingDebtOne,
        int256 netUnderlyingDebtTwo,
        PrimeRate[2] memory pr,
        bool checkMinBorrow
    ) internal {
        VaultAccountSecondaryDebtShareStorage storage accountStorage = 
            LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];
        // Check maturity
        uint256 accountMaturity = accountStorage.maturity;
        require(accountMaturity == maturity || accountMaturity == 0);

        int256 accountDebtOne = VaultStateLib.readDebtStorageToUnderlying(pr[0], maturity, accountStorage.accountDebtOne);
        int256 accountDebtTwo = VaultStateLib.readDebtStorageToUnderlying(pr[1], maturity, accountStorage.accountDebtTwo);
        if (netUnderlyingDebtOne != 0) {
            accountDebtOne = accountDebtOne.add(netUnderlyingDebtOne);

            _updateTotalSecondaryDebt(
                vaultConfig, account, vaultConfig.secondaryBorrowCurrencies[0], maturity, netUnderlyingDebtOne, pr[0]
            );

            accountStorage.accountDebtOne = VaultStateLib.calculateDebtStorage(pr[0], maturity, accountDebtOne)
                .neg().toUint().toUint80();
        }

        if (netUnderlyingDebtTwo != 0) {
            accountDebtTwo = accountDebtTwo.add(netUnderlyingDebtTwo);

            _updateTotalSecondaryDebt(
                vaultConfig, account, vaultConfig.secondaryBorrowCurrencies[1], maturity, netUnderlyingDebtTwo, pr[1]
            );

            accountStorage.accountDebtTwo = VaultStateLib.calculateDebtStorage(pr[1], maturity, accountDebtTwo)
                .neg().toUint().toUint80();
        }

        if (checkMinBorrow) {
            // No overflow on negation due to overflow checks above
            require(accountDebtOne == 0 || vaultConfig.minAccountSecondaryBorrow[0] <= -accountDebtOne, "min borrow");
            require(accountDebtTwo == 0 || vaultConfig.minAccountSecondaryBorrow[1] <= -accountDebtTwo, "min borrow");
        }

        _setAccountMaturity(accountStorage, accountDebtOne, accountDebtTwo, maturity.toUint40());
    }

    function _updateTotalSecondaryDebt(
        VaultConfig memory vaultConfig,
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 netUnderlyingDebt,
        PrimeRate memory pr
    ) private {
        VaultStateStorage storage balance = LibStorage.getVaultSecondaryBorrow()
            [vaultConfig.vault][maturity][currencyId];
        int256 totalDebtUnderlying = VaultStateLib.readDebtStorageToUnderlying(pr, maturity, balance.totalDebt);
        
        // Set the new debt underlying to storage
        totalDebtUnderlying = totalDebtUnderlying.add(netUnderlyingDebt);
        VaultStateLib.setTotalDebtStorage(
            balance, pr, vaultConfig, currencyId, maturity, totalDebtUnderlying, false // not settled
        );

        // Emit a mint or burn event for the account's secondary debt
        int256 vaultDebtAmount;
        if (netUnderlyingDebt > 0 && maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // Calculate debt storage for prime cash requires the underlying value to be negative
            vaultDebtAmount = VaultStateLib.calculateDebtStorage(pr, maturity, netUnderlyingDebt.neg()).neg();
        } else {
            vaultDebtAmount = VaultStateLib.calculateDebtStorage(pr, maturity, netUnderlyingDebt);
        }

        Emitter.emitVaultSecondaryDebt(
            account, vaultConfig.vault, currencyId, maturity, vaultDebtAmount
        );
    }

    /// @notice Executes a secondary currency lend or borrow
    function _executeSecondaryCurrencyTrade(
        VaultConfig memory vaultConfig,
        PrimeRate memory pr,
        uint16 currencyId,
        uint256 maturity,
        int256 netDebtInUnderlying,
        uint32 slippageLimit
    ) private returns (int256 netPrimeCash) {
        require(currencyId != vaultConfig.borrowCurrencyId);
        if (netDebtInUnderlying == 0) return 0;

        if (maturity != Constants.PRIME_CASH_VAULT_MATURITY) {
            netPrimeCash = VaultConfiguration.executeTrade(
                currencyId,
                vaultConfig.vault,
                maturity,
                netDebtInUnderlying,
                slippageLimit,
                vaultConfig.maxBorrowMarketIndex,
                block.timestamp
            );

            // Require that borrows always succeed
            if (netDebtInUnderlying < 0) require(netPrimeCash > 0, "Borrow Failed");
        }

        // If netPrimeCash is zero then either lending has failed (due to 0% interest) or the maturity
        // specified is the prime cash maturity. In both cases, calculate the netPrimeCash using the
        // the prime rate.
        if (netPrimeCash == 0) {
            netPrimeCash = pr.convertFromUnderlying(netDebtInUnderlying).neg();

            // See reasoning in VaultAccountLib.lendToExitVault
            if (maturity != Constants.PRIME_CASH_VAULT_MATURITY) {
                // Updates some state to track lending at zero for off chain accounting.
                PrimeCashExchangeRate.updateSettlementReserveForVaultsLendingAtZero(
                    vaultConfig.vault,
                    currencyId,
                    maturity,
                    netPrimeCash.neg(),
                    netDebtInUnderlying
                );
            }
        }
    }

    /**** Secondary Borrow Settlement ****/

    function settleSecondaryBorrow(VaultConfig memory vaultConfig, address account) internal {
        if (!vaultConfig.hasSecondaryBorrows()) return;

        VaultAccountSecondaryDebtShareStorage storage accountStorage = 
            LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];
        uint256 storedMaturity = accountStorage.maturity;

        // NOTE: we can read account debt directly since prime cash maturities never enter this block of code.
        int256 accountDebtOne = -int256(uint256(accountStorage.accountDebtOne));
        int256 accountDebtTwo = -int256(uint256(accountStorage.accountDebtTwo));
        
        if (storedMaturity == 0) {
            // Handles edge condition where an account is holding vault shares past maturity without
            // any debt position.
            require(accountDebtOne == 0 && accountDebtTwo == 0);
        } else {
            // Prime Cash maturity is uint40.max which means it will revert at this require statement
            require(storedMaturity <= block.timestamp); // dev: invalid maturity
        }

        (int256 primeCashRefundOne, int256 primeCashRefundTwo) = VaultAccountLib.clearVaultAccountSecondaryCash(
            account, vaultConfig.vault
        );

        if (vaultConfig.secondaryBorrowCurrencies[0] != 0) {
            // Burn previous refund if exists
            Emitter.emitVaultMintOrBurnCash(
                account, vaultConfig.vault, vaultConfig.secondaryBorrowCurrencies[0], storedMaturity, primeCashRefundOne.neg()
            );

            (accountDebtOne, primeCashRefundOne) = _settleTotalSecondaryBalance(
                vaultConfig.vault,
                account,
                vaultConfig.secondaryBorrowCurrencies[0],
                storedMaturity,
                accountDebtOne,
                primeCashRefundOne
            );
            accountStorage.accountDebtOne = accountDebtOne.neg().toUint().toUint80();

            // Mint new refund if it exists
            Emitter.emitVaultMintOrBurnCash(
                account, vaultConfig.vault, vaultConfig.secondaryBorrowCurrencies[0], Constants.PRIME_CASH_VAULT_MATURITY, primeCashRefundOne
            );
        }

        if (vaultConfig.secondaryBorrowCurrencies[1] != 0) {
            // Burn previous refund if exists
            Emitter.emitVaultMintOrBurnCash(
                account, vaultConfig.vault, vaultConfig.secondaryBorrowCurrencies[1], storedMaturity, primeCashRefundTwo.neg()
            );

            (accountDebtTwo, primeCashRefundTwo) = _settleTotalSecondaryBalance(
                vaultConfig.vault,
                account,
                vaultConfig.secondaryBorrowCurrencies[1],
                storedMaturity,
                accountDebtTwo,
                primeCashRefundTwo
            );
            accountStorage.accountDebtTwo = accountDebtTwo.neg().toUint().toUint80();

            // Mint new refund if it exists
            Emitter.emitVaultMintOrBurnCash(
                account, vaultConfig.vault, vaultConfig.secondaryBorrowCurrencies[1], Constants.PRIME_CASH_VAULT_MATURITY, primeCashRefundTwo
            );
        }

        if (primeCashRefundOne > 0 || primeCashRefundTwo > 0) {
            // Sets refunds if they exist
            VaultAccountLib.setVaultAccountSecondaryCash(account, vaultConfig.vault, primeCashRefundOne, primeCashRefundTwo);
        }

        _setAccountMaturity(accountStorage, accountDebtOne, accountDebtTwo, Constants.PRIME_CASH_VAULT_MATURITY);
    }

    /// @notice The first account to settle a secondary balance will trigger an update of the total
    /// borrow capacity on the prime cash vault. This does not affect prime cash utilization, it exists
    /// to properly update the accounting for the maxBorrowCapacity.
    function _settleTotalSecondaryBalance(
        address vault,
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 accountfCashDebt,
        int256 primeCashRefund
    ) private returns (int256 accountPrimeDebt, int256 finalPrimeCashRefund) {
        PrimeRate memory pr = PrimeRateLib.buildPrimeRateStateful(currencyId);

        VaultStateStorage storage primeSecondaryState = LibStorage.getVaultSecondaryBorrow()
            [vault][Constants.PRIME_CASH_VAULT_MATURITY][currencyId];

        // NOTE: maturity may be zero in the edge condition of a liquidator who holds vault shares
        if (maturity != 0) {
            VaultStateStorage storage totalBalance = 
                LibStorage.getVaultSecondaryBorrow()[vault][maturity][currencyId];
            int256 totalfCashDebt = -int256(totalBalance.totalDebt);

            if (!totalBalance.isSettled) {
                VaultStateLib.settleTotalDebtToPrimeCash(
                    primeSecondaryState, vault, currencyId, maturity, totalfCashDebt
                );

                totalBalance.isSettled = true;
                totalBalance.totalDebt = 0;
            }
        }

        // address(0) is used here to suppress the emitted event
        if (maturity != 0) {
            // When maturity is zero, accountPrimeDebt is zero
            accountPrimeDebt = PrimeRateLib.convertSettledfCashInVault(
                currencyId, maturity, accountfCashDebt, address(0)
            );
        }

        // Any excess prime cash will be returned to the account in prime cash refund
        (accountPrimeDebt, finalPrimeCashRefund) = VaultAccountLib.repayAccountPrimeDebtAtSettlement(
            pr, primeSecondaryState, currencyId, vault, primeCashRefund, accountPrimeDebt
        );

        // Burn the fCash debt amount
        Emitter.emitVaultSecondaryDebt(
            account, vault, currencyId, maturity, accountfCashDebt.neg()
        );

        // Mint the prime debt amount
        Emitter.emitVaultSecondaryDebt(
            account, vault, currencyId, Constants.PRIME_CASH_VAULT_MATURITY, accountPrimeDebt
        );
    }

    function _setAccountMaturity(
        VaultAccountSecondaryDebtShareStorage storage accountStorage,
        int256 accountDebtOne,
        int256 accountDebtTwo,
        uint40 maturity
    ) private {
        if (accountDebtOne == 0 && accountDebtTwo == 0) {
            // If both debt shares are cleared to zero, clear the maturity as well.
            accountStorage.maturity = 0;
        } else {
            // In all other cases, set the account to the designated maturity
            accountStorage.maturity = maturity;
        }
    }
}