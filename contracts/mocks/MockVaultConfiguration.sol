// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/vaults/VaultConfiguration.sol";
import "../internal/vaults/VaultState.sol";
import "../internal/vaults/VaultAccount.sol";
import "../internal/balances/TokenHandler.sol";
import "../internal/balances/BalanceHandler.sol";

contract MockVaultConfiguration {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using VaultAccountLib for VaultAccount;
    event VaultChange(address indexed vault, bool enabled);
    event VaultPauseStatus(address indexed vault, bool enabled);
    event VaultShortfall(uint16 indexed currencyId, address indexed vault, int256 shortfall);
    event ProtocolInsolvency(uint16 indexed currencyId, address indexed vault, int256 shortfall);

    function getVaultConfigView(
        address vault
    ) public view returns (VaultConfig memory vaultConfig) {
        return VaultConfiguration.getVaultConfigView(vault);
    }

    function setVaultEnabledStatus(
        address vault,
        bool enable
    ) external {
        VaultConfiguration.setVaultEnabledStatus(vault, enable);
        assert (getVaultConfigView(vault).getFlag(VaultConfiguration.ENABLED) == enable);
    }

    function getFlag(address vault, uint16 flagID) external view returns (bool) {
        return VaultConfiguration.getVaultConfigView(vault).getFlag(flagID);
    }

    function setVaultConfig(
        address vault,
        VaultConfigStorage calldata vaultConfig
    ) external {
        VaultConfiguration.setVaultConfig(vault, vaultConfig);
    }

    function assessVaultFees(
        address vault,
        VaultAccount memory vaultAccount,
        int256 fCash,
        uint256 timeToMaturity
    ) external returns (VaultAccount memory, int256 totalReserve, int256 nTokenCashBalance) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        vaultConfig.assessVaultFees(vaultAccount, fCash, timeToMaturity);

        address nTokenAddress = nTokenHandler.nTokenAddress(vaultConfig.borrowCurrencyId);
        (totalReserve, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(Constants.RESERVE, vaultConfig.borrowCurrencyId);
        (nTokenCashBalance, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(nTokenAddress, vaultConfig.borrowCurrencyId);

        return (vaultAccount, totalReserve, nTokenCashBalance);
    }

    function setMaxBorrowCapacity(
        address vault,
        uint16 currencyId,
        uint80 maxBorrowCapacity
    ) external {
        VaultConfiguration.setMaxBorrowCapacity(vault, currencyId, maxBorrowCapacity);
    }

    function updateUsedBorrowCapacity(
        address vault,
        uint16 currencyId,
        int256 netfCash
    ) external returns (int256 totalBorrowCapacity) {
        return VaultConfiguration.updateUsedBorrowCapacity(vault, currencyId, netfCash);
    }

    function deposit(
        address vault,
        address account,
        int256 cashToTransferExternal,
        uint256 additionalTokensDeposited,
        uint256 maturity,
        bytes calldata data
    ) external returns (uint256 strategyTokensMinted) {
        return VaultConfiguration.getVaultConfigView(vault).deposit(
            account, cashToTransferExternal, maturity, additionalTokensDeposited, data
        );
    }

    function redeem(
        address vault,
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        int256 assetAmountToRepay,
        bytes calldata data
    ) external returns (int256 assetCashInternalRaised) {
        return VaultConfiguration.getVaultConfigView(vault).redeem(
            account, strategyTokens, maturity, assetAmountToRepay, data
        );
    }

    /*** Vault State Methods ***/

    function getVaultState(address vault, uint256 maturity) public view returns (VaultState memory) {
        return VaultStateLib.getVaultState(vault, maturity);
    }

    function getRemainingSettledTokens(address vault, uint256 maturity) external view returns (
        uint256 remainingStrategyTokens, int256 remainingAssetCash
    ) {
        return VaultStateLib.getRemainingSettledTokens(vault, maturity);
    }

    function setVaultState(address vault, VaultState memory vaultState) external {
        return vaultState.setVaultState(vault);
    }

    function setSettledVaultState(address vault, uint256 maturity, uint256 blockTime) external {
        return VaultStateLib.setSettledVaultState(
            getVaultState(vault, maturity),
            getVaultConfigView(vault),
            getVaultConfigView(vault).assetRate,
            maturity,
            blockTime
        );
    }

    function exitMaturity(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 vaultSharesToRedeem
    ) external pure returns (uint256 strategyTokensWithdrawn, VaultState memory, VaultAccount memory) {
        strategyTokensWithdrawn = vaultState.exitMaturity(vaultAccount, vaultSharesToRedeem);
        return (strategyTokensWithdrawn, vaultState, vaultAccount);
    }

    function enterMaturity(
        address vault,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 strategyTokenDeposit,
        uint256 additionalTokenDeposit,
        bytes calldata vaultData
    ) external returns (VaultState memory, VaultAccount memory) {
        vaultState.enterMaturity(
            vaultAccount, getVaultConfigView(vault), strategyTokenDeposit, additionalTokenDeposit, vaultData
        );
        return (vaultState, vaultAccount);
    }

    function getCashValueOfShare(
        address vault,
        address account,
        VaultState memory vaultState,
        uint256 vaultShares
    ) external view returns (int256 assetCashValue) {
        assetCashValue = vaultState.getCashValueOfShare(getVaultConfigView(vault), account, vaultShares);
    }

    function getPoolShare(
        VaultState memory vaultState,
        uint256 vaultShares
    ) external pure returns (uint256 assetCash, uint256 strategyTokens) {
        return vaultState.getPoolShare(vaultShares);
    }

    function calculateCollateralRatio(
        address vault,
        VaultAccount memory vaultAccount,
        VaultState memory vaultState
    ) external view returns (int256 collateralRatio, int256 vaultShareValue) {
        (collateralRatio, vaultShareValue) = getVaultConfigView(vault).calculateCollateralRatio(
            vaultState,
            vaultAccount.account,
            vaultAccount.vaultShares,
            vaultAccount.fCash
        );
    }

    /*** Vault Account Methods ***/
    function getVaultAccount(address account, address vault) external view returns (VaultAccount memory) {
        return VaultAccountLib.getVaultAccount(account, getVaultConfigView(vault));
    }

    function setVaultAccount(VaultAccount memory vaultAccount, address vault) external {
        vaultAccount.setVaultAccount(getVaultConfigView(vault));
    }

    function settleVaultAccount(
        address vault,
        VaultAccount memory vaultAccount,
        uint256 blockTime
    ) external returns (VaultAccount memory, uint256) {
        uint256 strategyTokens = vaultAccount.settleVaultAccount(getVaultConfigView(vault), blockTime);

        return (vaultAccount, strategyTokens);
    }

    // function depositIntoAccount(
    //     VaultAccount memory vaultAccount,
    //     address transferFrom,
    //     uint16 borrowCurrencyId,
    //     uint256 _depositAmountExternal,
    //     bool useUnderlying
    // ) external returns (VaultAccount memory) {
    //     vaultAccount.depositIntoAccount(transferFrom, borrowCurrencyId, _depositAmountExternal, useUnderlying);
    //     return vaultAccount;
    // }

    // function transferTempCashBalance(
    //     VaultAccount memory vaultAccount,
    //     uint16 borrowCurrencyId,
    //     bool useUnderlying
    // ) external returns (VaultAccount memory) {
    //     VaultConfig memory vaultConfig;
    //     vaultConfig.borrowCurrencyId = borrowCurrencyId;
    //     vaultConfig.assetRate = AssetRate.buildAssetRateStateful(borrowCurrencyId);
    //     vaultAccount.transferTempCashBalance(vaultConfig, useUnderlying);
    //     return vaultAccount;
    // }

    function calculateDeleverageAmount(
        VaultAccount memory vaultAccount,
        address vault,
        int256 vaultShareValue
    ) external view returns (
        int256 maxLiquidatorDepositAssetCash, bool mustLiquidateFullAmount
    ) {
        return vaultAccount.calculateDeleverageAmount(
            getVaultConfigView(vault),
            vaultShareValue
        );
    }

    /*** Set Other Globals ***/
    function setReserveBalance(uint16 currencyId, int256 balance) external {
        BalanceHandler.setReserveCashBalance(currencyId, balance);
    }

    function getReserveBalance(uint16 currencyId) external view returns (int256 cashBalance) {
        (cashBalance, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(address(0), currencyId);
    }

    function setToken(
        uint16 currencyId,
        AssetRateAdapter rateOracle,
        uint8 underlyingDecimals,
        TokenStorage memory assetToken,
        TokenStorage memory underlyingToken,
        address nTokenAddress
    ) external {
        TokenHandler.setToken(currencyId, true, underlyingToken);
        TokenHandler.setToken(currencyId, false, assetToken);

        nTokenHandler.setNTokenAddress(currencyId, nTokenAddress);

        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
        store[currencyId] = AssetRateStorage({
            rateOracle: rateOracle,
            underlyingDecimalPlaces: underlyingDecimals
        });
    }

    function getCurrencyAndRates(uint16 currencyId) external view returns (
        Token memory assetToken,
        Token memory underlyingToken,
        ETHRate memory /* ethRate */,
        AssetRateParameters memory assetRate
    ) {
        assetToken = TokenHandler.getAssetToken(currencyId);
        underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
        assetRate = AssetRate.buildAssetRateView(currencyId);
    }

    function getLendingPool() external pure returns (address) {
        return address(0);
    }

}