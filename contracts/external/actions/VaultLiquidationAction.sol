// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    Token,
    VaultState,
    VaultAccountHealthFactors,
    VaultConfig,
    VaultAccount,
    PrimeRate
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {ActionGuards} from "./ActionGuards.sol";
import {Emitter} from "../../internal/Emitter.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../../internal/pCash/PrimeCashExchangeRate.sol";
import {VaultConfiguration} from "../../internal/vaults/VaultConfiguration.sol";
import {VaultAccountLib} from "../../internal/vaults/VaultAccount.sol";
import {VaultValuation} from "../../internal/vaults/VaultValuation.sol";
import {VaultSecondaryBorrow} from "../../internal/vaults/VaultSecondaryBorrow.sol";
import {VaultStateLib} from "../../internal/vaults/VaultState.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";

import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";
import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";

import {
    IVaultLiquidationAction,
    IVaultAccountHealth
} from "../../../interfaces/notional/IVaultController.sol";

contract VaultLiquidationAction is ActionGuards, IVaultLiquidationAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using PrimeRateLib for PrimeRate;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;


    /// @notice If an account is below the minimum collateral ratio, this method wil deleverage (liquidate)
    /// that account. `depositAmountPrimeCash` in the borrow currency will be transferred from the liquidator
    /// and used to offset the account's debt position. The liquidator will receive either vaultShares or
    /// cash depending.
    /// @param account the address that will exit the vault
    /// @param vault the vault to enter
    /// @param liquidator the address that will receive profits from liquidation
    /// @param currencyIndex 0 refers to primary borrow, 1 or 2 will refer to one of the secondary
    /// currencies (if any)
    /// @param depositUnderlyingInternal amount of underlying to deposit, in 8 decimal underlying precision
    /// @return vaultSharesToLiquidator amount of vaultShares received from liquidation
    /// @return depositAmountPrimeCash amount of prime cash deposited from liquidation
    function deleverageAccount(
        address account,
        address vault,
        address liquidator,
        uint16 currencyIndex,
        int256 depositUnderlyingInternal
    ) external payable nonReentrant override returns (
        uint256 vaultSharesToLiquidator,
        int256 depositAmountPrimeCash
    ) {
        require(currencyIndex < 3);
        (
            VaultConfig memory vaultConfig,
            VaultAccount memory vaultAccount,
            VaultState memory vaultState
        ) = _authenticateDeleverage(account, vault, liquidator);

        PrimeRate memory pr;
        // Currency Index is validated in this method
        (
            depositUnderlyingInternal,
            vaultSharesToLiquidator,
            pr
        ) = IVaultAccountHealth(address(this)).calculateDepositAmountInDeleverage(
            currencyIndex, vaultAccount, vaultConfig, vaultState, depositUnderlyingInternal
        );
        require(depositUnderlyingInternal > 0); // dev: cannot liquidate zero balance

        uint16 currencyId = vaultConfig.borrowCurrencyId;
        if (currencyIndex == 1) currencyId = vaultConfig.secondaryBorrowCurrencies[0];
        else if (currencyIndex == 2) currencyId = vaultConfig.secondaryBorrowCurrencies[1];

        Token memory token = TokenHandler.getUnderlyingToken(currencyId);
        // Excess ETH is returned to the liquidator natively
        (/* */, depositAmountPrimeCash) = TokenHandler.depositUnderlyingExternal(
            liquidator, currencyId, token.convertToExternal(depositUnderlyingInternal), pr, false 
        );

        Emitter.emitVaultDeleverage(
            liquidator, account, vault, currencyId, vaultState.maturity,
            currencyIndex == 0 ? depositAmountPrimeCash : 0, vaultSharesToLiquidator, pr
        );

        // Do not skip the min borrow check here
        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToLiquidator);
        if (vaultAccount.maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // Vault account will not incur a cash balance if they are in the prime cash maturity, their debts
            // will be paid down directly.
            _reduceAccountDebt(
                vaultConfig, vaultState, vaultAccount, pr, currencyIndex, depositUnderlyingInternal, true
            );
            depositAmountPrimeCash = 0;
        }

        // Check min borrow in this liquidation method, the deleverage calculation should adhere to the min borrow
        vaultAccount.setVaultAccountForLiquidation(vaultConfig, currencyIndex, depositAmountPrimeCash, true);

        _transferVaultSharesToLiquidator(
            liquidator, vaultConfig, vaultSharesToLiquidator, vaultAccount.maturity
        );
    }

    /// @notice If an account has a cash balance, a liquidator can purchase the cash and provide
    /// fCash to the account to reduce it's debt balance.
    function liquidateVaultCashBalance(
        address account,
        address vault,
        address liquidator,
        uint256 currencyIndex,
        int256 fCashDeposit
    ) external nonReentrant override returns (int256 cashToLiquidator) {
        (
            VaultConfig memory vaultConfig,
            VaultAccount memory vaultAccount,
            VaultState memory vaultState
        ) = _authenticateDeleverage(account, vault, liquidator);

        uint16 currencyId;
        PrimeRate memory pr;
        int256 fCashBalance;
        int256 cashBalance;

        if (currencyIndex == 0) {
            currencyId = vaultConfig.borrowCurrencyId;
            pr = vaultConfig.primeRate;
            fCashBalance = vaultAccount.accountDebtUnderlying;
            cashBalance = vaultAccount.tempCashBalance;
        } else if (currencyIndex < 3) {
            (currencyId, pr, fCashBalance, cashBalance) = _getSecondaryCashFactors(
                vaultConfig, currencyIndex, account
            );
        } else {
            revert(); // dev: invalid currency index
        }

        {
            // At this point, the prime rates have already been accrued statefully so using a view method is ok.
            (int256 fCashRequired, int256 discountFactor) = IVaultAccountHealth(address(this))
                .getfCashRequiredToLiquidateCash(currencyId, vaultAccount.maturity, cashBalance);

            cashToLiquidator = pr.convertFromUnderlying(fCashDeposit.mulInRatePrecision(discountFactor));
            if (cashToLiquidator > cashBalance) {
                // Cap the fCash deposit to the cash balance available at the discount factor
                fCashDeposit = fCashRequired;
                cashToLiquidator = cashBalance;
            }
        }

        // Cap the fCash deposit to the fcash balance held by the account
        require(0 < fCashDeposit && fCashDeposit <= fCashBalance.neg());

        _transferCashToVault(
            vaultAccount, liquidator, vault, currencyId, fCashDeposit, cashToLiquidator
        );

        _reduceAccountDebt(vaultConfig, vaultState, vaultAccount, pr, currencyIndex, fCashDeposit, false);
        vaultAccount.setVaultAccountForLiquidation(vaultConfig, currencyIndex, cashToLiquidator.neg(), false);
    }

    function liquidateExcessVaultCash(
        address account,
        address vault,
        address liquidator,
        uint256 excessCashIndex,
        uint256 debtIndex,
        uint256 _depositUnderlyingInternal
    ) external payable nonReentrant override returns (int256 cashToLiquidator) {
        (
            VaultConfig memory vaultConfig,
            VaultAccount memory vaultAccount,
            /* VaultState memory vaultState */
        ) = _authenticateDeleverage(account, vault, liquidator);

        // This liquidation is only valid when there are secondary borrows
        require(vaultConfig.hasSecondaryBorrows());
        PrimeRate[2] memory primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
        // All prime rates have accrued statefully at this point, so it is ok to get account health factors which uses
        // a view method to accrue prime cash -- it will read the values that have already accrued to this block.
        (VaultAccountHealthFactors memory h, /* */, /* */) =  IVaultAccountHealth(address(this)).getVaultAccountHealthFactors(
            account, vault
        );
        // Validate that there is debt and cash. This ensures that excessCashIndex != debtIndex and
        // excessCashIndex < 3 and debtIndex < 3. It also validates that the currency indexes are valid
        // because netDebtOutstanding == 0 for an unused secondary borrow currency.
        require(0 < h.netDebtOutstanding[excessCashIndex]);
        require(h.netDebtOutstanding[debtIndex] < 0);

        VaultSecondaryBorrow.ExcessVaultCashFactors memory f = VaultSecondaryBorrow.getLiquidateExcessCashFactors(
            vaultConfig, primeRates, excessCashIndex, debtIndex
        );

        int256 depositUnderlyingInternal = _depositUnderlyingInternal.toInt();
        cashToLiquidator = f.excessCashPR.convertFromUnderlying(
            depositUnderlyingInternal
                .mul(f.exchangeRate)
                .mul(vaultConfig.excessCashLiquidationBonus)
                .div(Constants.PERCENTAGE_DECIMALS)
                .div(f.rateDecimals)
        );

        if (h.netDebtOutstanding[excessCashIndex] < cashToLiquidator) {
            // Limit the deposit to what is held by the account
            cashToLiquidator = h.netDebtOutstanding[excessCashIndex];
            depositUnderlyingInternal = f.excessCashPR.convertToUnderlying(cashToLiquidator)
                .mul(Constants.PERCENTAGE_DECIMALS)
                .mul(f.rateDecimals)
                .div(f.exchangeRate)
                .div(vaultConfig.excessCashLiquidationBonus);
        }

        int256 depositAmountPrimeCash = f.debtPR.convertFromUnderlying(depositUnderlyingInternal);
        vaultAccount.setVaultAccountForLiquidation(vaultConfig, excessCashIndex, cashToLiquidator.neg(), false);
        vaultAccount.setVaultAccountForLiquidation(vaultConfig, debtIndex, depositAmountPrimeCash, false);

        TokenHandler.withdrawPrimeCash(
            liquidator, f.excessCashCurrencyId, cashToLiquidator, f.excessCashPR, false
        );
        Emitter.emitVaultMintOrBurnCash(account, vault, f.excessCashCurrencyId, vaultAccount.maturity, cashToLiquidator.neg());

        // Deposit the debtIndex from the liquidator
        TokenHandler.depositExactToMintPrimeCash(
            liquidator, f.debtCurrencyId, depositAmountPrimeCash, f.debtPR, false
        );
        Emitter.emitVaultMintOrBurnCash(account, vault, f.debtCurrencyId, vaultAccount.maturity, depositAmountPrimeCash);
    }

    function _transferCashToVault(
        VaultAccount memory vaultAccount,
        address liquidator,
        address vault,
        uint16 currencyId,
        int256 fCashDeposit,
        int256 cashToLiquidator
    ) internal {
        bool mustCheckFC = SettleAssetsExternal.transferCashToVaultLiquidator(
            liquidator, vault, vaultAccount.account, currencyId, vaultAccount.maturity, fCashDeposit, cashToLiquidator
        );

        if (mustCheckFC) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(liquidator);
        }
        emit VaultAccountCashLiquidation(
            vault, vaultAccount.account, liquidator, currencyId, fCashDeposit, cashToLiquidator
        );
    }

    /// @notice Authenticates a call to the deleverage method
    function _authenticateDeleverage(
        address account,
        address vault,
        address liquidator
    ) private returns (
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        VaultState memory vaultState
    ) {
        // Do not allow invalid accounts to liquidate
        requireValidAccount(liquidator);
        require(liquidator != vault);

        // Cannot liquidate self, if a vault needs to deleverage itself as a whole it has other methods 
        // in VaultAction to do so.
        require(account != msg.sender);
        require(account != liquidator);

        vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        require(vaultConfig.getFlag(VaultConfiguration.DISABLE_DELEVERAGE) == false);

        // Authorization rules for deleveraging
        if (vaultConfig.getFlag(VaultConfiguration.ONLY_VAULT_DELEVERAGE)) {
            require(msg.sender == vault);
        } else {
            require(msg.sender == liquidator);
        }

        vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);

        // Vault accounts that are not settled must be settled first by calling settleVaultAccount
        // before liquidation. settleVaultAccount is not permissioned so anyone may settle the account.
        require(block.timestamp < vaultAccount.maturity, "Must Settle");

        if (vaultAccount.maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // Returns the updated prime vault state
            vaultState = vaultAccount.accruePrimeCashFeesToDebtInLiquidation(vaultConfig);
        } else {
            vaultState = VaultStateLib.getVaultState(vaultConfig, vaultAccount.maturity);
        }
    }

    function _reduceAccountDebt(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        PrimeRate memory primeRate,
        uint256 currencyIndex,
        int256 depositUnderlyingInternal,
        bool checkMinBorrow
    ) private {
        if (currencyIndex == 0) {
            vaultAccount.updateAccountDebt(vaultState, depositUnderlyingInternal, 0);
            vaultState.setVaultState(vaultConfig);
        } else {
            // Only set one of the prime rates, the other prime rate is not used since
            // the net debt amount is set to zero
            PrimeRate[2] memory pr;
            pr[currencyIndex - 1] = primeRate;

            VaultSecondaryBorrow.updateAccountSecondaryDebt(
                vaultConfig,
                vaultAccount.account,
                vaultAccount.maturity,
                currencyIndex == 1 ? depositUnderlyingInternal : 0,
                currencyIndex == 2 ? depositUnderlyingInternal : 0,
                pr,
                checkMinBorrow
            );
        }
    }

    /// @notice Transfers liquidator profits in the form of vault shares to be returned to the liquidator
    function _transferVaultSharesToLiquidator(
        address receiver,
        VaultConfig memory vaultConfig,
        uint256 vaultSharesToLiquidator,
        uint256 maturity
    ) private {
        // Liquidator will receive vault shares that they can redeem by calling exitVault. If the liquidator has a
        // leveraged position on then their collateral ratio will increase
        VaultAccount memory liquidator = VaultAccountLib.getVaultAccount(receiver, vaultConfig);
        // The liquidator must be able to receive the vault shares (i.e. not be in the vault at all or be in the
        // vault at the same maturity). If the liquidator has fCash in the current maturity then their collateral
        // ratio will increase as a result of the liquidation, no need to check their collateral position.
        require(liquidator.maturity == 0 || liquidator.maturity == maturity, "Maturity Mismatch"); // dev: has vault shares
        liquidator.maturity = maturity;
        liquidator.vaultShares = liquidator.vaultShares.add(vaultSharesToLiquidator);
        liquidator.setVaultAccount({vaultConfig: vaultConfig, checkMinBorrow: true, emitEvents: false});
    }

    function _getSecondaryCashFactors(
        VaultConfig memory vaultConfig,
        uint256 currencyIndex,
        address account
    ) private returns (uint16 currencyId, PrimeRate memory pr, int256 fCashBalance, int256 cashBalance) {
        PrimeRate[2] memory primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
        (/* */, int256 debtOne, int256 debtTwo) = VaultSecondaryBorrow.getAccountSecondaryDebt(vaultConfig, account, primeRates);

        // Cash balances refer to cash held on the account against debt, not prime cash balances held by the vault.
        // Those are included in the vault share value.
        (int256 cashOne, int256 cashTwo) = VaultSecondaryBorrow.getSecondaryCashHeld(account, vaultConfig.vault);

        currencyId = vaultConfig.secondaryBorrowCurrencies[currencyIndex - 1];
        pr = primeRates[currencyIndex - 1];
        // Return the correct pair of debt and cash balances
        (fCashBalance, cashBalance) = currencyIndex == 1 ? (debtOne, cashOne) : (debtTwo, cashTwo);
    }

    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(SettleAssetsExternal));
    }
}