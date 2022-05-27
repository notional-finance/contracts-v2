// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/vaults/VaultConfiguration.sol";
import "../internal/vaults/VaultState.sol";
import "../internal/vaults/VaultAccount.sol";
import "../internal/balances/TokenHandler.sol";

contract MockVaultConfiguration {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using VaultAccountLib for VaultAccount;

    function getVaultConfigView(
        address vault
    ) public view returns (VaultConfig memory vaultConfig) {
        return VaultConfiguration.getVaultConfigView(vault);
    }

    function setStakedNTokenUnstakeSignal(uint16 currencyId, uint256 maturity, uint88 unstakeSignal) external {
        nTokenTotalUnstakeSignalStorage storage t = LibStorage.getStakedNTokenTotalUnstakeSignal()[currencyId][maturity];
        t.totalUnstakeSignal = unstakeSignal;
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

    function getCurrentMaturity(address vault, uint256 blockTime) external view returns (uint256) {
        return VaultConfiguration.getVaultConfigView(vault).getCurrentMaturity(blockTime);
    }

    function getNTokenFee(
        address vault,
        int256 fCash,
        uint256 timeToMaturity
    ) external view returns (int256 snTokenFee, int256 reserveFee) {
        return VaultConfiguration.getVaultConfigView(vault).getVaultFees(fCash, timeToMaturity);
    }

    function getBorrowCapacity(
        address vault,
        uint256 maturity,
        int256 stakedNTokenUnderlyingPV,
        uint256 totalSupply,
        uint256 blockTime
    ) external view returns (
        int256 totalUnderlyingCapacity,
        // Inside this method, total outstanding debt is a positive integer
        int256 nextMaturityPredictedCapacity,
        int256 totalOutstandingDebt,
        int256 nextMaturityDebt
    ) {
        VaultState memory vaultState = VaultStateLib.getVaultState(vault, maturity);
        return VaultConfiguration.getVaultConfigView(vault).getBorrowCapacity(
            vaultState, stakedNTokenUnderlyingPV, totalSupply, blockTime
        );
    }

    function checkTotalBorrowCapacity(
        address vault,
        VaultState memory vaultState,
        uint256 blockTime
    ) external {
        VaultConfiguration.getVaultConfigView(vault).checkTotalBorrowCapacity(vaultState, blockTime);
    }

    function deposit(
        address vault,
        int256 cashToTransferExternal,
        bytes calldata data
    ) external returns (uint256 strategyTokensMinted) {
        return VaultConfiguration.getVaultConfigView(vault).deposit(cashToTransferExternal, data);
    }

    function redeem(
        address vault,
        uint256 strategyTokens,
        bytes calldata data
    ) external returns (int256 assetCashInternalRaised) {
        return VaultConfiguration.getVaultConfigView(vault).redeem(strategyTokens, data);
    }
    

    /*** Vault State Methods ***/

    function getVaultState(address vault, uint256 maturity) external view returns (VaultState memory) {
        return VaultStateLib.getVaultState(vault, maturity);
    }

    function setVaultState(address vault, VaultState memory vaultState) external {
        return vaultState.setVaultState(vault);
    }

    function exitMaturityPool(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 vaultSharesToRedeem
    ) external pure returns (uint256 strategyTokensWithdrawn, VaultState memory, VaultAccount memory) {
        strategyTokensWithdrawn = vaultState.exitMaturityPool(vaultAccount, vaultSharesToRedeem);
        return (strategyTokensWithdrawn, vaultState, vaultAccount);
    }

    function enterMaturityPool(
        address vault,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        bytes calldata vaultData
    ) external returns (VaultState memory, VaultAccount memory) {
        vaultState.enterMaturityPool(vaultAccount, getVaultConfigView(vault), vaultData);
        return (vaultState, vaultAccount);
    }

    function getCashValueOfShare(
        address vault,
        VaultState memory vaultState,
        uint256 vaultShares
    ) external view returns (int256 assetCashValue) {
        (assetCashValue, /* */) = vaultState.getCashValueOfShare(getVaultConfigView(vault), vaultShares);
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
    ) external view returns (int256 collateralRatio) {
        return getVaultConfigView(vault).calculateCollateralRatio(
            vaultState,
            vaultAccount.vaultShares,
            vaultAccount.fCash,
            vaultAccount.escrowedAssetCash
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
        VaultState memory vaultState,
        uint256 blockTime
    ) external returns (VaultAccount memory, VaultState memory) {
        vaultAccount.settleVaultAccount(
            getVaultConfigView(vault),
            vaultState,
            blockTime
        );

        return (vaultAccount, vaultState);
    }

    function requiresSettlement(VaultAccount memory vaultAccount) external pure returns (bool) {
        return vaultAccount.requiresSettlement();
    }


    /*** Set Other Globals ***/

    function setToken(
        uint256 currencyId,
        AssetRateAdapter rateOracle,
        uint8 underlyingDecimals,
        TokenStorage memory assetToken,
        TokenStorage memory underlyingToken
    ) external {
        TokenHandler.setToken(currencyId, true, underlyingToken);
        TokenHandler.setToken(currencyId, false, assetToken);

        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
        store[currencyId] = AssetRateStorage({
            rateOracle: rateOracle,
            underlyingDecimalPlaces: underlyingDecimals
        });
    }

    function getCurrencyAndRates(uint16 currencyId) external view returns (
        Token memory assetToken,
        Token memory underlyingToken,
        ETHRate memory ethRate,
        AssetRateParameters memory assetRate
    ) {
        assetToken = TokenHandler.getAssetToken(currencyId);
        underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
        assetRate = AssetRate.buildAssetRateView(currencyId);
    }

}