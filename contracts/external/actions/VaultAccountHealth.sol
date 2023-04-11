// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    VaultState,
    VaultBorrowCapacityStorage,
    VaultAccountStorage,
    VaultAccount,
    VaultConfig,
    VaultAccountSecondaryDebtShareStorage,
    VaultStateStorage
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {Emitter} from "../../internal/Emitter.sol";
import {VaultConfiguration} from "../../internal/vaults/VaultConfiguration.sol";
import {VaultAccountLib} from "../../internal/vaults/VaultAccount.sol";
import {VaultValuation, VaultAccountHealthFactors} from "../../internal/vaults/VaultValuation.sol";
import {VaultSecondaryBorrow} from "../../internal/vaults/VaultSecondaryBorrow.sol";
import {VaultStateLib} from "../../internal/vaults/VaultState.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../../internal/pCash/PrimeCashExchangeRate.sol";

import {IVaultAccountHealth} from "../../../interfaces/notional/IVaultController.sol";

contract VaultAccountHealth is IVaultAccountHealth {
    using PrimeRateLib for PrimeRate;
    using VaultConfiguration for VaultConfig;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;

    /// @notice Checks if a vault account has sufficient collateral to perform an action, reverts if it does not.
    /// Called at the end of VaultAccountActions after all values have been set in storage
    function checkVaultAccountCollateralRatio(address vault, address account) external override {
        require(account != vault);
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig, vaultAccount.maturity);
        // There should never bee any temp cash balance during this check (this is also enforced by
        // the setVaultAccount method).
        require(vaultAccount.tempCashBalance == 0);
        // Require that secondary cash is zero during this method as well
        VaultAccountLib.checkVaultAccountSecondaryCash(account, vault);

        (int256 collateralRatio, /* */) = VaultValuation.getCollateralRatioFactorsStateful(
            vaultConfig, vaultState, account, vaultAccount.vaultShares, vaultAccount.accountDebtUnderlying
        );

        // Enforce a maximum account collateral ratio that must be satisfied for vault entry and vault exit,
        // to ensure that accounts are not "free riding" on vaults by entering without incurring borrowing
        // costs. We only enforce this if the account has any assets remaining in the vault (so that they
        // may exit in full at any time.)
        if (vaultAccount.vaultShares > 0) {
            require(collateralRatio <= vaultConfig.maxRequiredAccountCollateralRatio, "Above Max Collateral");
        }

        require(vaultConfig.minCollateralRatio <= collateralRatio, "Insufficient Collateral");
    }

    function getVaultAccountHealthFactors(address account, address vault) external view override returns (
        VaultAccountHealthFactors memory h,
        int256[3] memory maxLiquidatorDepositUnderlying,
        uint256[3] memory vaultSharesToLiquidator
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        // NOTE: matured vaults may have a higher collateral ratio than reported here after settlement if
        // the vault is holding prime cash. If the vault is holding prime cash and the account is settled
        // manually the vault's debts will be repaid by its prime cash claim. This can only increase its
        // collateral ratio.
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig, vaultAccount.maturity);

        PrimeRate[2] memory primeRates;
        if (vaultConfig.hasSecondaryBorrows()) {
            primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateView(vaultConfig, block.timestamp);
        }

        VaultSecondaryBorrow.SecondaryExchangeRates memory er;
        (h, er) = VaultValuation.calculateAccountHealthFactors(vaultConfig, vaultAccount, vaultState, primeRates);

        int256 vaultShares = vaultAccount.vaultShares.toInt();
        if (h.collateralRatio < vaultConfig.minCollateralRatio) {
            // depositUnderlyingInternal is set to type(int256).max here, getLiquidationFactors will limit
            // this to the calculated maxLiquidatorDeposit and calculate vault shares to liquidator accordingly
            (maxLiquidatorDepositUnderlying[0], vaultSharesToLiquidator[0]) = 
                VaultValuation.getLiquidationFactors(vaultConfig, h, er, 0, vaultShares, type(int256).max);

            if (vaultConfig.hasSecondaryBorrows()) {
                (maxLiquidatorDepositUnderlying[1], vaultSharesToLiquidator[1]) = 
                    VaultValuation.getLiquidationFactors(vaultConfig, h, er, 1, vaultShares, type(int256).max);
                (maxLiquidatorDepositUnderlying[2], vaultSharesToLiquidator[2]) = 
                    VaultValuation.getLiquidationFactors(vaultConfig, h, er, 2, vaultShares, type(int256).max);
            }
        }
    }

    /// @notice Returns the fCash required to liquidate a given vault cash balance.
    function getfCashRequiredToLiquidateCash(
        uint16 currencyId,
        uint256 maturity,
        int256 vaultAccountCashBalance
    ) external view override returns (int256 fCashRequired, int256 discountFactor) {
        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);
        discountFactor = VaultValuation.getLiquidateCashDiscountFactor(pr, currencyId, maturity);
        fCashRequired = pr.convertToUnderlying(vaultAccountCashBalance).divInRatePrecision(discountFactor);
    }

    function getVaultAccount(address account, address vault) external override view returns (VaultAccount memory vaultAccount) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);
    }

    function getVaultAccountWithFeeAccrual(address account, address vault) external override view returns (
        VaultAccount memory vaultAccount,
        int256 accruedPrimeVaultFeeInUnderlying
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);

        if (vaultAccount.maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // Save this because it is re-written inside the calculate vault fees method
            uint256 lastUpdateBlockTime = vaultAccount.lastUpdateBlockTime;
            accruedPrimeVaultFeeInUnderlying = vaultConfig.primeRate.convertToUnderlying(
                vaultConfig.calculateVaultFees(
                    vaultAccount,
                    vaultConfig.primeRate.convertFromUnderlying(vaultAccount.accountDebtUnderlying).neg(),
                    vaultAccount.maturity,
                    block.timestamp
                )
            );

            // Reset the last update block time and add the accrued vault fee to the total debt (use
            // subtraction since debts are negative).
            vaultAccount.lastUpdateBlockTime = lastUpdateBlockTime;
            vaultAccount.accountDebtUnderlying = vaultAccount.accountDebtUnderlying.sub(
                accruedPrimeVaultFeeInUnderlying
            );
        }
    }

    function getVaultConfig(
        address vault
    ) external view override returns (VaultConfig memory vaultConfig) {
        vaultConfig = VaultConfiguration.getVaultConfigView(vault);
    }

    function getVaultState(
        address vault,
        uint256 maturity
    ) external view override returns (VaultState memory vaultState) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        vaultState = VaultStateLib.getVaultState(vaultConfig, maturity);

        if (maturity <= block.timestamp) {
            // Convert settled fCash to how much debt is owed post maturity
            vaultState.totalDebtUnderlying = vaultConfig.primeRate.convertToUnderlying(
                vaultConfig.primeRate.convertSettledfCashView(
                    vaultConfig.borrowCurrencyId,
                    maturity,
                    vaultState.totalDebtUnderlying,
                    block.timestamp
                )
            );
        }
    }

    function getSecondaryBorrow(
        address vault,
        uint16 currencyId,
        uint256 maturity
    ) external view override returns (int256 totalDebtUnderlying) {
        VaultStateStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vault][maturity][currencyId];
        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);
        totalDebtUnderlying = -int256(uint256(balance.totalDebt));

        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            totalDebtUnderlying = pr.convertDebtStorageToUnderlying(totalDebtUnderlying);
        } else if (maturity <= block.timestamp) {
            // Convert settled fCash to how much debt is owed post maturity
            totalDebtUnderlying = pr.convertToUnderlying(
                pr.convertSettledfCashView(
                    currencyId, maturity, totalDebtUnderlying, block.timestamp
                )
            );
        }
    }

    function getBorrowCapacity(
        address vault,
        uint16 currencyId
    ) external view override returns (
        uint256 currentPrimeDebtUnderlying,
        uint256 totalfCashDebt,
        uint256 maxBorrowCapacity
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];
        totalfCashDebt = cap.totalfCashDebt;
        maxBorrowCapacity = cap.maxBorrowCapacity;

        PrimeRate memory pr; 
        if (currencyId == vaultConfig.borrowCurrencyId) {
            pr = vaultConfig.primeRate;
        } else {
            (pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);
        }
        currentPrimeDebtUnderlying = VaultStateLib.getCurrentPrimeDebt(vaultConfig, pr, currencyId).neg().toUint();
    }

    function getVaultAccountSecondaryDebt(
        address account,
        address vault
    ) external override view returns (
        uint256 maturity,
        int256[2] memory accountSecondaryDebt,
        int256[2] memory accountSecondaryCashHeld
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        PrimeRate[2] memory pr = VaultSecondaryBorrow.getSecondaryPrimeRateView(vaultConfig, block.timestamp);
        VaultAccount memory vaultAccount = VaultAccountLib.getVaultAccount(account, vaultConfig);

        (
            maturity,
            accountSecondaryDebt[0],
            accountSecondaryDebt[1]
        ) = VaultSecondaryBorrow.getAccountSecondaryDebt(vaultConfig, account, pr);

        (
            accountSecondaryCashHeld[0],
            accountSecondaryCashHeld[1]
        ) = VaultSecondaryBorrow.getSecondaryCashHeld(vaultAccount.account, vaultConfig.vault);
    }

    function calculateDepositAmountInDeleverage(
        uint256 currencyIndex,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 depositUnderlyingInternal
    ) external override returns (int256, uint256, PrimeRate memory) {
        // This method is only intended for use during deleverage account
        require(msg.sender == address(this)); // dev: unauthorized

        // Return the proper prime rate object
        PrimeRate memory pr = vaultConfig.primeRate;
        VaultAccountHealthFactors memory h;
        VaultSecondaryBorrow.SecondaryExchangeRates memory er;
        {
            PrimeRate[2] memory primeRates;
            if (vaultConfig.hasSecondaryBorrows()) {
                primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);

                // Set the proper prime rate object to return if liquidating secondary
                if (currencyIndex > 0) pr = primeRates[currencyIndex - 1];
            } else {
                require(currencyIndex == 0);
            }

            (h, er) = VaultValuation.calculateAccountHealthFactors(vaultConfig, vaultAccount, vaultState, primeRates);
            // Require account is eligible for liquidation
            require(h.collateralRatio < vaultConfig.minCollateralRatio , "Sufficient Collateral");
        }
        
        // depositUnderlyingInternal is capped to the max liquidator deposit local inside this method,
        // vault shares to liquidator is calculated based on the deposit amount returned here.
        uint256 vaultSharesToLiquidator;
        (depositUnderlyingInternal, vaultSharesToLiquidator) = VaultValuation.getLiquidationFactors(
            // vaultShares cannot overflow int256 due to storage size, manual conversion required to
            // reduce stack size
            vaultConfig, h, er, currencyIndex, int256(vaultAccount.vaultShares), depositUnderlyingInternal
        );

        return (depositUnderlyingInternal, vaultSharesToLiquidator, pr);
    }

    /// @notice Returns the signed value for a given vault ERC1155 id
    function signedBalanceOfVaultTokenId(address account, uint256 id) external view override returns (int256) {
        (uint256 assetType, uint16 currencyId, uint256 maturity, address vault) = Emitter.decodeVaultId(id);
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);

        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage.getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultConfig.vault];

        uint256 storedMaturity = s.maturity;
        if (maturity != storedMaturity) return 0;

        if (assetType == Constants.VAULT_SHARE_ASSET_TYPE) {
            // No overflow due to storage size
            return int256(s.vaultShares);
        } else if (currencyId == vaultConfig.borrowCurrencyId && assetType == Constants.VAULT_DEBT_ASSET_TYPE) {
            // Returns a positive number that reflects the stored value, not the underlying valuation
            return int256(s.accountDebt);
        } else if (currencyId == vaultConfig.borrowCurrencyId && assetType == Constants.VAULT_CASH_ASSET_TYPE) {
            return int256(s.primaryCash);
        }

        if (vaultConfig.hasSecondaryBorrows()) {
            int256 one;
            int256 two;
            if (assetType == Constants.VAULT_DEBT_ASSET_TYPE) {
                VaultAccountSecondaryDebtShareStorage storage secondary = 
                    LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];
                (one, two) = (int256(secondary.accountDebtOne), int256(secondary.accountDebtTwo));
            } else if (assetType == Constants.VAULT_CASH_ASSET_TYPE) {
                (one, two) = (int256(s.secondaryCashOne), int256(s.secondaryCashTwo));
            }

            if (currencyId == vaultConfig.secondaryBorrowCurrencies[0]) return one;
            if (currencyId == vaultConfig.secondaryBorrowCurrencies[1]) return two;
        }
        
        return 0;
    }

    function getLiquidateCashDiscountFactor(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) external view override returns (int256) {
        (PrimeRate memory pr, /* factors */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
        return VaultValuation.getLiquidateCashDiscountFactor(
            pr, currencyId, maturity
        );
    }
}
