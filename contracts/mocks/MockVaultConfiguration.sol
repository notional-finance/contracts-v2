// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/vaults/VaultConfiguration.sol";
import "../internal/vaults/VaultState.sol";
import "../internal/vaults/VaultAccount.sol";
import "../internal/vaults/VaultSecondaryBorrow.sol";
import "../internal/vaults/VaultValuation.sol";
import "../internal/balances/TokenHandler.sol";
import "../internal/balances/BalanceHandler.sol";
import "./valuation/AbstractSettingsRouter.sol";
import {AssetRateAdapter, AssetRateStorage, ETHRateStorage} from "../global/Types.sol";

contract MockVaultConfiguration is AbstractSettingsRouter {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using VaultAccountLib for VaultAccount;
    event VaultChange(address indexed vault, bool enabled);
    event VaultPauseStatus(address indexed vault, bool enabled);
    event VaultShortfall(uint16 indexed currencyId, address indexed vault, int256 shortfall);
    event ProtocolInsolvency(uint16 indexed currencyId, address indexed vault, int256 shortfall);
    /// @notice Emitted when the borrow capacity on a vault changes
    event VaultBorrowCapacityChange(address indexed vault, uint16 indexed currencyId, uint256 totalUsedBorrowCapacity);
    /// @notice Emits when the totalPrimeDebt changes due to borrowing
    event PrimeDebtChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 totalPrimeDebt
    );
    event ReserveFeeAccrued(uint16 indexed currencyId, int256 fee);

    /// @notice Emits when the totalPrimeSupply changes due to token deposits or withdraws
    event PrimeSupplyChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 lastTotalUnderlyingValue
    );

    event TotalfCashDebtOutstandingChanged(
        uint16 indexed currencyId,
        uint256 indexed maturity,
        int256 totalfCashDebt,
        int256 netDebtChange
    );

    event VaultStateSettled(
        address indexed vault,
        uint16 indexed currencyId,
        uint256 indexed maturity,
        int256 totalfCashDebt,
        int256 settledPrimeCash
    );

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    function setToken(uint16 currencyId, TokenStorage calldata token) external {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        store[currencyId][true] = token;
    }

    function getCurrency(uint16 currencyId) external view returns (
        Token memory /* assetToken */,
        Token memory underlyingToken
    ) {
        underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
    }

    function getVaultConfigView(address vault) public view returns (VaultConfig memory vaultConfig) {
        return VaultConfiguration.getVaultConfigView(vault);
    }

    function getVaultConfig(address vault) public returns (VaultConfig memory vaultConfig) {
        return VaultConfiguration.getVaultConfigStateful(vault);
    }

    function setVaultConfig(
        address vault,
        VaultConfigStorage calldata vaultConfig
    ) external {
        VaultConfiguration.setVaultConfig(vault, vaultConfig);
    }

    /*** Vault State Methods ***/

    function getVaultState(address vault, uint256 maturity) public view returns (VaultState memory) {
        return VaultStateLib.getVaultState(getVaultConfigView(vault), maturity);
    }

    function setVaultState(address vault, VaultState memory vaultState) external {
        return vaultState.setVaultState(getVaultConfig(vault));
    }

    /*** Vault Account Methods ***/
    function getVaultAccount(address account, address vault) public view returns (VaultAccount memory) {
        return VaultAccountLib.getVaultAccount(account, getVaultConfigView(vault));
    }

    function setVaultAccount(VaultAccount memory vaultAccount, address vault) external {
        vaultAccount.setVaultAccount(getVaultConfig(vault), true, true);
    }

    function setfCashBorrowCapacity(
        address vault,
        uint16 currencyId,
        int256 netfCashDebt
    ) external {
        VaultConfiguration.updatefCashBorrowCapacity(vault, currencyId, netfCashDebt);
    }

    function setMaxBorrowCapacity(
        address vault,
        uint16 currencyId,
        uint80 maxBorrowCapacity
    ) external {
        VaultConfiguration.setMaxBorrowCapacity(vault, currencyId, maxBorrowCapacity);
    }

    function getSecondaryCashHeld(
        address account,
        address vault
    ) external view returns (int256 secondaryCashOne, int256 secondaryCashTwo) {
        return VaultSecondaryBorrow.getSecondaryCashHeld(account, vault);
    }

    function setVaultAccountPrimaryCash(
        address account,
        address vault,
        uint80 primaryCash
    ) external {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[account][vault];
        
        s.primaryCash = primaryCash;
    }
}

contract MockVaultConfigurationState is MockVaultConfiguration {
    using VaultStateLib for VaultState;

    constructor(address settingsLib) MockVaultConfiguration(settingsLib) { }

    function getToken(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getUnderlyingToken(currencyId);
    }

    function getVaultSecondaryCash(
        address vault, uint256 maturity, uint16 currencyId
    ) external view returns (VaultStateStorage memory){
        return LibStorage.getVaultSecondaryBorrow()[vault][maturity][currencyId];
    }

    function getCurrentPrimeDebt(address vault) external view returns (int256 totalPrimeDebtInUnderlying) {
        VaultConfig memory vaultConfig = getVaultConfigView(vault);
        return VaultStateLib.getCurrentPrimeDebt(vaultConfig, vaultConfig.primeRate, vaultConfig.borrowCurrencyId);
    }

    function enterMaturity(
        address vault,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 strategyTokenDeposit,
        bytes calldata vaultData
    ) external returns (VaultState memory, VaultAccount memory) {
        vaultState.enterMaturity(vaultAccount, getVaultConfig(vault), strategyTokenDeposit, vaultData);
        return (vaultState, vaultAccount);
    }

    function getCashValueOfShare(
        address vault,
        address account,
        VaultState memory vaultState,
        uint256 vaultShares
    ) external view returns (int256 underlyingValue) {
        underlyingValue = VaultValuation.getPrimaryUnderlyingValueOfShare(
            vaultState, getVaultConfigView(vault), account, vaultShares
        );
    }

    function exitMaturity(
        address vault,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 vaultSharesToRedeem
    ) external returns (VaultState memory, VaultAccount memory) {
        vaultState.exitMaturity(vaultAccount, getVaultConfig(vault), vaultSharesToRedeem);
        return (vaultState, vaultAccount);
    }

}

contract MockVaultTokenTransfers is MockVaultConfiguration {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using VaultAccountLib for VaultAccount;

    constructor(address settingsLib) MockVaultConfiguration(settingsLib) { }

    function getToken(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getUnderlyingToken(currencyId);
    }

    function setVaultEnabledStatus(
        address vault,
        bool enable
    ) external {
        VaultConfiguration.setVaultEnabledStatus(vault, enable);
        assert (getVaultConfig(vault).getFlag(VaultConfiguration.ENABLED) == enable);
    }

    function setVaultDeleverageStatus(
        address vault,
        bool enable
    ) external {
        VaultConfiguration.setVaultDeleverageStatus(vault, enable);
        assert (getVaultConfig(vault).getFlag(VaultConfiguration.DISABLE_DELEVERAGE) == enable);
    }

    function getFlag(address vault, uint16 flagID) external view returns (bool) {
        return VaultConfiguration.getVaultConfigView(vault).getFlag(flagID);
    }

    function assessVaultFees(
        address vault,
        VaultAccount memory vaultAccount,
        int256 fCash,
        uint256 maturity,
        uint256 blockTime
    ) external returns (VaultAccount memory, int256 totalReserve, int256 nTokenCashBalance) {
        VaultConfig memory vaultConfig = getVaultConfig(vault);
        vaultConfig.assessVaultFees(vaultAccount, fCash, maturity, blockTime);

        address nTokenAddress = nTokenHandler.nTokenAddress(vaultConfig.borrowCurrencyId);
        totalReserve = BalanceHandler.getPositiveCashBalance(Constants.FEE_RESERVE, vaultConfig.borrowCurrencyId);
        nTokenCashBalance = BalanceHandler.getPositiveCashBalance(nTokenAddress, vaultConfig.borrowCurrencyId);

        return (vaultAccount, totalReserve, nTokenCashBalance);
    }

    function deposit(
        address vault,
        address account,
        int256 cashToTransferExternal,
        uint256 maturity,
        bytes calldata data
    ) external returns (uint256 strategyTokensMinted) {
        return getVaultConfig(vault).deposit(account, cashToTransferExternal, maturity, data);
    }

    function getPrimeCashHoldingsOracle(uint16 currencyId) external view returns (IPrimeCashHoldingsOracle) {
        return PrimeCashExchangeRate.getPrimeCashHoldingsOracle(currencyId);
    }

    function redeemWithDebtRepayment(
        VaultAccount memory vaultAccount,
        address vault,
        address receiver,
        uint256 strategyTokens,
        bytes calldata data
    ) external payable returns (uint256 underlyingToReceiver) {
        // maturity and data are just forwarded to the vault, not relevant for this unit test
        return getVaultConfig(vault).redeemWithDebtRepayment(
            vaultAccount, receiver, strategyTokens, data
        );
    }

    function depositForRollPosition(
        address vault,
        VaultAccount memory vaultAccount,
        uint256 depositAmountExternal
    ) external payable returns (int256) {
        getVaultConfig(vault).depositMarginForVault(vaultAccount, depositAmountExternal);
        return vaultAccount.tempCashBalance;
    }

    function setReserveBalance(uint16 currencyId, int256 balance) external {
        BalanceHandler.setReserveCashBalance(currencyId, balance);
    }

    function getReserveBalance(uint16 currencyId) external view returns (int256 cashBalance) {
        cashBalance = BalanceHandler.getPositiveCashBalance(address(0), currencyId);
    }
}

contract MockVaultAccount is MockVaultConfiguration {
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;

    event VaultSharesChange(
        int256 totalVaultShareUnderlyingValue,
        int256 strategyTokenUnderlyingValue,
        uint256 totalVaultShares,
        uint256 vaultSharesMinted
    );

    constructor(address settingsLib) MockVaultConfiguration(settingsLib) { }

    int256 _vaultShareValue;

    function settleVaultAccount(
        address vault,
        VaultAccount memory vaultAccount
    ) external returns (VaultAccount memory) {
        vaultAccount.settleVaultAccount(getVaultConfig(vault));
        return vaultAccount;
    }

    function getCashValueOfShare(
        address vault,
        address account,
        VaultState memory vaultState,
        uint256 vaultShares
    ) public view returns (int256 underlyingValue) {
        underlyingValue = VaultValuation.getPrimaryUnderlyingValueOfShare(vaultState, getVaultConfigView(vault), account, vaultShares);
    }

    function updateAccountDebt(
        VaultAccount memory vaultAccount,
        VaultState memory vaultState,
        int256 netUnderlyingDebt,
        int256 netPrimeCash
    ) external view returns (VaultState memory, VaultAccount memory) {
        vaultAccount.updateAccountDebt(vaultState, netUnderlyingDebt, netPrimeCash);
        return (vaultState, vaultAccount);
    }

    function setVaultAccountForLiquidation(
        address vault,
        VaultAccount memory vaultAccount,
        uint256 currencyIndex,
        int256 netCashBalanceChange,
        bool checkMinBorrow
    ) external {
        vaultAccount.setVaultAccountForLiquidation(
            getVaultConfig(vault),
            currencyIndex,
            netCashBalanceChange,
            checkMinBorrow
        );
    }
}

contract MockVaultSecondaryBorrow is MockVaultConfiguration {
    constructor(address settingsLib) MockVaultConfiguration(settingsLib) { }

    function updateAccountSecondaryDebt(
        address vault,
        address account,
        uint256 maturity,
        int256 netUnderlyingDebtOne,
        int256 netUnderlyingDebtTwo,
        bool checkMinBorrow
    ) external {
        VaultConfig memory vaultConfig = getVaultConfig(vault);
        PrimeRate[2] memory primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
        (/* */, int256 accountDebtOne, int256 accountDebtTwo) = VaultSecondaryBorrow.getAccountSecondaryDebt(
            vaultConfig,
            account,
            primeRates
        );

        VaultSecondaryBorrow.updateAccountSecondaryDebt(
            vaultConfig,
            account,
            maturity,
            // Allow max specification here to clear debt
            netUnderlyingDebtOne == type(int256).min ? -accountDebtOne : netUnderlyingDebtOne,
            netUnderlyingDebtTwo == type(int256).min ? -accountDebtTwo : netUnderlyingDebtTwo,
            primeRates,
            checkMinBorrow,
            true
        );
    }

    function getAccountSecondaryDebt(address vault, address account) external view returns (
        uint256 maturity,
        int256 accountDebtOne,
        int256 accountDebtTwo
    ) {
        VaultConfig memory vaultConfig = getVaultConfigView(vault);
        return VaultSecondaryBorrow.getAccountSecondaryDebt(
            vaultConfig,
            account,
            VaultSecondaryBorrow.getSecondaryPrimeRateView(vaultConfig, block.timestamp)
        );
    }

    function getTotalSecondaryDebtOutstanding(address vault, uint256 maturity) external view returns (
        int256 totalDebtInPrimary,
        int256 totalDebtOne,
        int256 totalDebtTwo
    ) {
        VaultConfig memory vaultConfig = getVaultConfigView(vault);
        VaultState memory vaultState = getVaultState(vault, maturity);
        PrimeRate[2] memory primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateView(vaultConfig, block.timestamp);

        mapping(uint256 => VaultStateStorage) storage store = LibStorage.getVaultSecondaryBorrow()
            [vaultConfig.vault][maturity];

        totalDebtOne = VaultStateLib.readDebtStorageToUnderlying(
            primeRates[0], maturity, store[vaultConfig.secondaryBorrowCurrencies[0]].totalDebt
        );

        totalDebtTwo = VaultStateLib.readDebtStorageToUnderlying(
            primeRates[1], maturity, store[vaultConfig.secondaryBorrowCurrencies[1]].totalDebt
        );
    }

    function setVaultAccountSecondaryCash(
        address account,
        address vault,
        int256 netSecondaryPrimeCashOne,
        int256 netSecondaryPrimeCashTwo
    ) external {
        VaultAccountLib.setVaultAccountSecondaryCash(account, vault, netSecondaryPrimeCashOne, netSecondaryPrimeCashTwo);
    }

    function settleSecondaryBorrow(address vault, address account) external {
        VaultConfig memory vaultConfig = getVaultConfig(vault);
        VaultSecondaryBorrow.settleSecondaryBorrow(vaultConfig, account);
    }
}

contract MockVaultValuation is MockVaultConfiguration {
    using VaultAccountLib for VaultAccount;
    using VaultConfiguration for VaultConfig;
    using PrimeRateLib for PrimeRate;

    constructor(address settingsLib) MockVaultConfiguration(settingsLib) { }

    event HealthFactors(VaultAccountHealthFactors h, int256 collateralRatio, int256 vaultShareValue);

    function calculateHealthFactors(
        address vault,
        VaultAccount memory vaultAccount,
        VaultState memory vaultState
    ) external {
        VaultConfig memory vaultConfig = getVaultConfig(vault);

        PrimeRate[2] memory primeRates;
        if (vaultConfig.hasSecondaryBorrows()) {
            primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
        }

        (VaultAccountHealthFactors memory h, /* er */) = VaultValuation.calculateAccountHealthFactors(vaultConfig, vaultAccount, vaultState, primeRates);

        (int256 collateralRatio, int256 vaultShareValue) = VaultValuation.getCollateralRatioFactorsStateful(
            vaultConfig, vaultState, vaultAccount.account, vaultAccount.vaultShares, vaultAccount.accountDebtUnderlying
        );

        // Get collateral ratio factors stateful requires a zero temp cash balance
        if (vaultAccount.tempCashBalance == 0) {
            require(collateralRatio == h.collateralRatio);
            require(vaultShareValue == h.vaultShareValueUnderlying);
        }

        emit HealthFactors(h, collateralRatio, vaultShareValue);
    }

    function getVaultAccountHealthFactors(
        address vault,
        VaultAccount memory vaultAccount,
        VaultState memory vaultState
    ) external view returns (
        VaultAccountHealthFactors memory h,
        int256[3] memory maxLiquidatorDepositUnderlying,
        uint256[3] memory vaultSharesToLiquidator,
        VaultSecondaryBorrow.SecondaryExchangeRates memory er
    ) {
        VaultConfig memory vaultConfig = getVaultConfigView(vault);

        PrimeRate[2] memory primeRates;
        if (vaultConfig.hasSecondaryBorrows()) {
            primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateView(vaultConfig, block.timestamp);
        }

        (h, er) = VaultValuation.calculateAccountHealthFactors(vaultConfig, vaultAccount, vaultState, primeRates);

        int256 vaultShares = int256(vaultAccount.vaultShares);
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

    function getLiquidationFactors(
        address vault,
        VaultAccountHealthFactors memory h,
        VaultSecondaryBorrow.SecondaryExchangeRates memory er,
        uint256 currencyIndex,
        int256 vaultShares,
        int256 depositAmountUnderlying
    ) external view returns (int256 maxLiquidatorDepositUnderlying, uint256 vaultSharesToLiquidator) {
        return VaultValuation.getLiquidationFactors(getVaultConfigView(vault), h, er, currencyIndex, vaultShares, depositAmountUnderlying);
    }

    function updateAccountSecondaryDebt(
        address vault,
        address account,
        uint256 maturity,
        int256 netUnderlyingDebtOne,
        int256 netUnderlyingDebtTwo,
        bool checkMinBorrow
    ) external {
        VaultConfig memory vaultConfig = getVaultConfig(vault);
        VaultSecondaryBorrow.updateAccountSecondaryDebt(
            vaultConfig,
            account,
            maturity,
            netUnderlyingDebtOne,
            netUnderlyingDebtTwo,
            VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig),
            checkMinBorrow,
            true
        );
    }

    function setVaultAccountSecondaryCash(
        address account,
        address vault,
        int256 netSecondaryUnderlyingOne,
        int256 netSecondaryUnderlyingTwo
    ) external {
        PrimeRate[2] memory primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(getVaultConfig(vault));
        return VaultAccountLib.setVaultAccountSecondaryCash(
            account,
            vault,
            primeRates[0].convertFromUnderlying(netSecondaryUnderlyingOne),
            primeRates[1].convertFromUnderlying(netSecondaryUnderlyingTwo)
        );
    }

    function getAccountSecondaryDebt(address vault, address account) external view returns (
        uint256 maturity,
        int256 accountDebtOne,
        int256 accountDebtTwo
    ) {
        VaultConfig memory vaultConfig = getVaultConfigView(vault);
        return VaultSecondaryBorrow.getAccountSecondaryDebt(
            vaultConfig,
            account,
            VaultSecondaryBorrow.getSecondaryPrimeRateView(vaultConfig, block.timestamp)
        );
    }


}