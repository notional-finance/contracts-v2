// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultAccount,
    VaultConfig,
    VaultState,
    VaultStateStorage
} from "../../global/Types.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {Token, TokenHandler} from "../balances/TokenHandler.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Constants} from "../../global/Constants.sol";
import {VaultConfiguration} from "./VaultConfiguration.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

/**
 * @notice VaultState holds a combination of asset cash and strategy tokens on behalf of the
 * vault accounts. When accounts enter or exit the pool they receive vault shares corresponding to
 * at the ratio of asset cash to strategy tokens in their maturity pool. A maturity pool may hold
 * asset cash during a risk-off event or as it unwinds to repay its debt at maturity.
 *
 * VaultState also holds the total borrowing for a given maturity.
 */
library VaultStateLib {
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using VaultConfiguration for VaultConfig;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    function getVaultState(
        address vault,
        uint256 maturity
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vault][maturity];

        vaultState.maturity = maturity;
        // fCash debts are represented as negative integers on the stack
        vaultState.totalfCash = -int256(int80(s.totalfCash));
        vaultState.isSettled = s.isSettled;
        vaultState.totalAssetCash = s.totalAssetCash;
        vaultState.totalStrategyTokens = s.totalStrategyTokens;
        vaultState.totalVaultShares = s.totalVaultShares;
        vaultState.settlementStrategyTokenValue = s.settlementStrategyTokenValue;
    }

    function setVaultState(VaultState memory vaultState, address vault) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vault][vaultState.maturity];

        require(vaultState.isSettled == false); // dev: cannot update vault state after settled

        s.totalfCash = vaultState.totalfCash.neg().toUint().toUint80();
        s.totalAssetCash = vaultState.totalAssetCash.toUint80();
        s.totalStrategyTokens = vaultState.totalStrategyTokens.toUint80();
        s.totalVaultShares = vaultState.totalVaultShares.toUint80();
    }

    function setSettledVaultState(
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 blockTime
    ) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][maturity];

        require(s.isSettled == false); // dev: cannot update vault state after settled
        require(maturity <= blockTime); // dev: cannot set settled state before maturity

        int256 singleTokenValueInternal = _getStrategyTokenValueUnderlyingInternal(
            vaultConfig.borrowCurrencyId,
            vaultConfig.vault,
            uint256(Constants.INTERNAL_TOKEN_PRECISION),
            maturity
        );

        s.isSettled = true;
        // Save off the value of a single strategy token at settlement
        s.settlementStrategyTokenValue = singleTokenValueInternal.toUint().toUint80();
    }

    /**
     * @notice Exits a maturity pool for an account given the shares to redeem. Asset cash will be credited
     * to tempCashBalance.
     * @param vaultState the current state of the pool
     * @param vaultAccount will use the maturity on the vault account to choose which pool to exit
     * @param vaultSharesToRedeem amount of shares to redeem
     * @return strategyTokensWithdrawn amount of strategy tokens withdrawn from the pool
     */
    function exitMaturityPool(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 vaultSharesToRedeem
    ) internal pure returns (uint256 strategyTokensWithdrawn) {
        require(vaultAccount.maturity == vaultState.maturity);
        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToRedeem);
        uint256 assetCashWithdrawn;
        (assetCashWithdrawn, strategyTokensWithdrawn) = exitMaturityPoolDirect(vaultState, vaultSharesToRedeem);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(SafeInt256.toInt(assetCashWithdrawn));
    }

    /**
     * @notice Does the pool math for withdraws, used for the liquidator in deleverage because we redeem
     * directly without touching the vault account.
     * @param vaultState the current state of the pool
     * @param vaultSharesToRedeem amount of shares to redeem
     * @return assetCashWithdrawn asset cash withdrawn from the pool
     * @return strategyTokensWithdrawn amount of strategy tokens withdrawn from the pool
     */
    function exitMaturityPoolDirect(
        VaultState memory vaultState,
        uint256 vaultSharesToRedeem
    ) internal pure returns (uint256 assetCashWithdrawn, uint256 strategyTokensWithdrawn) {
        // Calculate the claim on cash tokens and strategy tokens
        (assetCashWithdrawn, strategyTokensWithdrawn) = getPoolShare(vaultState, vaultSharesToRedeem);

        // Remove tokens from the pool
        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(assetCashWithdrawn);
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.sub(strategyTokensWithdrawn);
        vaultState.totalVaultShares = vaultState.totalVaultShares.sub(vaultSharesToRedeem);
    }

    /**
     * @notice Enters a maturity pool (including depositing cash and minting vault shares). If the maturity
     * on the account is changing, then we will first redeem from the old maturity pool and move the account's
     * positions to the new maturity pool.
     * @param vaultAccount will update maturity and reduce tempCashBalance to zero
     * @param vaultConfig vault config
     * @param vaultState vault state for the maturity we are entering
     * @param strategyTokenDeposit any existing amount of strategy tokens to deposit from settlement
     * @param vaultData calldata to pass to the vault
     */
    function enterMaturityPool(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 strategyTokenDeposit,
        bytes calldata vaultData
    ) internal {
        // If the vault state is holding asset cash this would mean that there is some sort of emergency de-risking
        // event or the vault is in the process of settling debts. In both cases, we do not allow accounts to enter
        // the vault.
        require(vaultAccount.tempCashBalance >= 0 && vaultState.totalAssetCash == 0);

        if (vaultAccount.maturity < vaultState.maturity) {
            // This condition can occur in three scenarios:
            //  - when an account is newly established
            //  - when an account is entering a maturity after settlement
            //  - when an account is rolling forward from a previous maturity
            require(vaultAccount.vaultShares == 0);
            vaultAccount.maturity = vaultState.maturity;
        } else {
            require(vaultAccount.maturity == vaultState.maturity);
        }

        // This will transfer the cash amount to the vault and mint strategy tokens which will be transferred
        // to the current contract.
        strategyTokenDeposit = strategyTokenDeposit.add(
            vaultConfig.deposit(vaultAccount.account, vaultAccount.tempCashBalance, vaultState.maturity, vaultData)
        );
        // Clear the cash balance after the deposit
        vaultAccount.tempCashBalance = 0;

        // Calculate the number of vault shares to mint to the account. Note that totalAssetCash is required to be zero
        // at this point.
        uint256 vaultSharesMinted;
        if (vaultState.totalVaultShares == 0) {
            vaultSharesMinted = strategyTokenDeposit;
        } else {
            vaultSharesMinted = strategyTokenDeposit.mul(vaultState.totalVaultShares).div(vaultState.totalStrategyTokens);
        }

        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.add(strategyTokenDeposit);
        vaultState.totalVaultShares = vaultState.totalVaultShares.add(vaultSharesMinted);
        vaultAccount.vaultShares = vaultAccount.vaultShares.add(vaultSharesMinted);
    }

    /** @notice Returns the component amounts for a given amount of vaultShares */
    function getPoolShare(
        VaultState memory vaultState,
        uint256 vaultShares
    ) internal pure returns (
        uint256 assetCash,
        uint256 strategyTokens
    ) {
        assetCash = vaultShares.mul(vaultState.totalAssetCash).div(vaultState.totalVaultShares);
        strategyTokens = vaultShares.mul(vaultState.totalStrategyTokens).div(vaultState.totalVaultShares);
    }

    function _getStrategyTokenValueUnderlyingInternal(
        uint16 currencyId,
        address vault,
        uint256 strategyTokens,
        uint256 maturity
    ) private view returns (int256) {
        Token memory token = TokenHandler.getUnderlyingToken(currencyId);
        // This will be true if the the token is "NonMintable" meaning that it does not have
        // an underlying token, only an asset token
        if (token.decimals == 0) token = TokenHandler.getAssetToken(currencyId);

        return token.convertToInternal(
            IStrategyVault(vault).convertStrategyToUnderlying(strategyTokens, maturity).toInt()
        );
    }

    /** @notice Returns the value in asset cash of a given amount of pool share */
    function getCashValueOfShare(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        uint256 vaultShares
    ) internal view returns (int256 assetCashValue) {
        if (vaultShares == 0) return 0;
        (uint256 assetCash, uint256 strategyTokens) = getPoolShare(vaultState, vaultShares);
        int256 underlyingInternalStrategyTokenValue = _getStrategyTokenValueUnderlyingInternal(
            vaultConfig.borrowCurrencyId, vaultConfig.vault, strategyTokens, vaultState.maturity
        );

        assetCashValue = vaultConfig.assetRate
            .convertFromUnderlying(underlyingInternalStrategyTokenValue)
            .add(assetCash.toInt());
    }
}