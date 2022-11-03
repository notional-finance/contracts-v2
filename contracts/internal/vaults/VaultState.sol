// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultAccount,
    VaultConfig,
    VaultState,
    VaultStateStorage,
    VaultSettledAssetsStorage
} from "../../global/Types.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {Token, TokenHandler} from "../balances/TokenHandler.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Constants} from "../../global/Constants.sol";
import {VaultConfiguration} from "./VaultConfiguration.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

/// @notice VaultState holds a combination of asset cash and strategy tokens on behalf of the
/// vault accounts. When accounts enter or exit the pool they receive vault shares corresponding to
/// at the ratio of asset cash to strategy tokens in the corresponding maturity. A maturity may hold
/// asset cash during a risk-off event or as it unwinds to repay its debt at maturity. A VaultState
/// will also hold settlement values after a vault is matured.
library VaultStateLib {
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using VaultConfiguration for VaultConfig;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    event VaultStateUpdate(
        address indexed vault,
        uint256 indexed maturity,
        int256 totalfCash,
        uint256 totalAssetCash,
        uint256 totalStrategyTokens,
        uint256 totalVaultShares
    );

    event VaultSettled(
        address indexed vault,
        uint256 indexed maturity,
        int256 totalfCash,
        uint256 totalAssetCash,
        uint256 totalStrategyTokens,
        uint256 totalVaultShares,
        int256 strategyTokenValue
    );

    event VaultEnterMaturity(
        address indexed vault,
        uint256 indexed maturity,
        address indexed account,
        uint256 underlyingTokensDeposited,
        uint256 cashTransferToVault,
        uint256 strategyTokenDeposited,
        uint256 vaultSharesMinted
    );

    function getVaultState(address vault, uint256 maturity) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vault][maturity];

        vaultState.maturity = maturity;
        // fCash debts are represented as negative integers on the stack
        vaultState.totalfCash = -int256(uint256(s.totalfCash));
        vaultState.isSettled = s.isSettled;
        vaultState.totalAssetCash = s.totalAssetCash;
        vaultState.totalStrategyTokens = s.totalStrategyTokens;
        vaultState.totalVaultShares = s.totalVaultShares;
        vaultState.settlementStrategyTokenValue = s.settlementStrategyTokenValue;
    }

    /// @notice Sets a vault state before it has been settled
    function setVaultState(VaultState memory vaultState, address vault) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vault][vaultState.maturity];

        require(vaultState.isSettled == false); // dev: cannot update vault state after settled

        s.totalfCash = vaultState.totalfCash.neg().toUint().toUint80();
        s.totalAssetCash = vaultState.totalAssetCash.toUint80();
        s.totalStrategyTokens = vaultState.totalStrategyTokens.toUint80();
        s.totalVaultShares = vaultState.totalVaultShares.toUint80();

        emit VaultStateUpdate(
            vault,
            vaultState.maturity,
            vaultState.totalfCash,
            vaultState.totalAssetCash,
            vaultState.totalStrategyTokens,
            vaultState.totalVaultShares
        );
    }

    /// @notice Settles a vault state by taking a snapshot of relevant values at settlement. This can only happen once
    /// per maturity.
    function setSettledVaultState(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        AssetRateParameters memory settlementRate,
        uint256 maturity,
        uint256 blockTime
    ) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][maturity];

        require(s.isSettled == false); // dev: cannot update vault state after settled
        require(maturity <= blockTime); // dev: cannot set settled state before maturity

        // This will work when there are secondary borrowed currencies (each individual account will have
        // a different secondary borrow amount) because when this is called there cannot be any secondary
        // borrowed amounts left. At that point all strategy tokens are worth the same.
        int256 singleTokenValueInternal = _getStrategyTokenValueUnderlyingInternal(
            vaultConfig.borrowCurrencyId,
            vaultConfig.vault,
            vaultConfig.vault, // Use the vault as the account for a globalized value
            uint256(Constants.INTERNAL_TOKEN_PRECISION),
            maturity
        );

        s.isSettled = true;
        // Save off the value of a single strategy token at settlement. This is possibly negative if a strategy
        // itself has become insolvent.
        s.settlementStrategyTokenValue = singleTokenValueInternal.toInt80();

        // Initializes the settled assets counters for individual account settlement. If these are reduced below
        // zero then they signify an account insolvency within the vault maturity.
        VaultSettledAssetsStorage storage settledAssets = LibStorage.getVaultSettledAssets()
            [vaultConfig.vault][maturity];
        settledAssets.remainingStrategyTokens = s.totalStrategyTokens;

        // This is the amount of residual asset cash left in the vault after repaying the fCash debt,
        // it can be negative if the entire vault is insolvent.
        settledAssets.remainingAssetCash = vaultState.totalAssetCash.toInt()
            .add(settlementRate.convertFromUnderlying(vaultState.totalfCash)).toInt80();

        emit VaultSettled(
            vaultConfig.vault,
            vaultState.maturity,
            vaultState.totalfCash,
            vaultState.totalAssetCash,
            vaultState.totalStrategyTokens,
            vaultState.totalVaultShares,
            singleTokenValueInternal
        );
    }

    function getRemainingSettledTokens(
        address vault,
        uint256 maturity
    ) internal view returns (uint256 remainingStrategyTokens, int256 remainingAssetCash) {
        VaultSettledAssetsStorage storage settledAssets = LibStorage.getVaultSettledAssets()
            [vault][maturity];
        remainingStrategyTokens = settledAssets.remainingStrategyTokens;
        remainingAssetCash = settledAssets.remainingAssetCash;
    }

    /// @notice Exits a maturity for an account given the shares to redeem. Asset cash will be credited
    /// to tempCashBalance.
    /// @param vaultState vault state
    /// @param vaultAccount will use the maturity on the vault account to choose which pool to exit
    /// @param vaultSharesToRedeem amount of shares to redeem
    /// @return strategyTokensWithdrawn amount of strategy tokens withdrawn from the pool
    function exitMaturity(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 vaultSharesToRedeem
    ) internal pure returns (uint256 strategyTokensWithdrawn) {
        require(vaultAccount.maturity == vaultState.maturity);
        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToRedeem);
        uint256 assetCashWithdrawn;
        (assetCashWithdrawn, strategyTokensWithdrawn) = exitMaturityDirect(vaultState, vaultSharesToRedeem);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(SafeInt256.toInt(assetCashWithdrawn));
    }

    
    /// @notice Does the pool math for withdraws, used for the liquidator in deleverage because we redeem
    /// directly without touching the vault account.
    /// @param vaultState the current state of the pool
    /// @param vaultSharesToRedeem amount of shares to redeem
    /// @return assetCashWithdrawn asset cash withdrawn from the pool
    /// @return strategyTokensWithdrawn amount of strategy tokens withdrawn from the pool
    function exitMaturityDirect(
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

    /// @notice Enters a maturity pool (including depositing cash and minting vault shares).
    /// @param vaultState vault state for the maturity we are entering
    /// @param vaultAccount will update maturity and vault shares and reduce tempCashBalance to zero
    /// @param vaultConfig vault config
    /// @param strategyTokenDeposit any existing amount of strategy tokens to deposit from settlement or during
    /// a roll vault position
    /// @param additionalUnderlyingExternal any additional tokens pre-deposited to the vault in enterVault
    /// @param vaultData calldata to pass to the vault
    function enterMaturity(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 strategyTokenDeposit,
        uint256 additionalUnderlyingExternal,
        bytes calldata vaultData
    ) internal returns (uint256 strategyTokensAdded) {
        // If the vault state is holding asset cash this would mean that there is some sort of emergency de-risking
        // event or the vault is in the process of settling debts. In both cases, we do not allow accounts to enter
        // the vault.
        require(vaultState.totalAssetCash == 0);
        // An account cannot enter a vault with a negative temp cash balance.  This can happen during roll vault where
        // an insufficient amount is borrowed to repay its previous maturity debt.
        require(vaultAccount.tempCashBalance >= 0);

        if (vaultAccount.maturity < vaultState.maturity) {
            // This condition can occur in three scenarios, in all of these scenarios it cannot have any claim on the
            // previous maturity's assets.
            //  - when an account is newly established
            //  - when an account is entering a maturity after settlement
            //  - when an account is rolling forward from a previous maturity
            require(vaultAccount.vaultShares == 0);
            vaultAccount.maturity = vaultState.maturity;
        } else {
            require(vaultAccount.maturity == vaultState.maturity);
        }

        uint256 vaultSharesMinted;
        if (strategyTokenDeposit > 0) {
            // If there is a deposit from a matured position or an account that is rolling
            // their position forward, then we set the strategy token deposit before we call
            // deposit so the vault will see the additional strategyTokens in VaultState if
            // it queries for the vault state.
            vaultSharesMinted = _setVaultSharesMinted(vaultState, vaultAccount, strategyTokenDeposit, vaultConfig.vault);
        }

        uint256 strategyTokensMinted = vaultConfig.deposit(
            vaultAccount.account, vaultAccount.tempCashBalance, vaultState.maturity, additionalUnderlyingExternal, vaultData
        );

        // Update the vault state again for the new tokens that were minted inside deposit.
        vaultSharesMinted = vaultSharesMinted.add(
            _setVaultSharesMinted(vaultState, vaultAccount, strategyTokensMinted, vaultConfig.vault)
        );

        emit VaultEnterMaturity(
            vaultConfig.vault,
            vaultState.maturity,
            vaultAccount.account,
            additionalUnderlyingExternal,
            // Overflow checked above
            uint256(vaultAccount.tempCashBalance),
            strategyTokenDeposit,
            vaultSharesMinted
        );

        // Clear the cash balance after the deposit
        vaultAccount.tempCashBalance = 0;

        // Return this value back to the caller
        strategyTokensAdded = strategyTokenDeposit.add(strategyTokensMinted);
    }

    function _setVaultSharesMinted(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 strategyTokens,
        address vault
    ) private returns (uint256 vaultSharesMinted) {
        if (vaultState.totalStrategyTokens == 0) {
            vaultSharesMinted = strategyTokens;
        } else {
            vaultSharesMinted = strategyTokens.mul(vaultState.totalVaultShares).div(vaultState.totalStrategyTokens);
        }

        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.add(strategyTokens);
        vaultState.totalVaultShares = vaultState.totalVaultShares.add(vaultSharesMinted);
        vaultAccount.vaultShares = vaultAccount.vaultShares.add(vaultSharesMinted);
        setVaultState(vaultState, vault);
    }

    /// @notice Returns the component amounts for a given amount of vaultShares
    function getPoolShare(
        VaultState memory vaultState,
        uint256 vaultShares
    ) internal pure returns (uint256 assetCash, uint256 strategyTokens) {
        if (vaultState.totalVaultShares > 0) {
            assetCash = vaultShares.mul(vaultState.totalAssetCash).div(vaultState.totalVaultShares);
            strategyTokens = vaultShares.mul(vaultState.totalStrategyTokens).div(vaultState.totalVaultShares);
        }
    }

    function _getStrategyTokenValueUnderlyingInternal(
        uint16 currencyId,
        address vault,
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) private view returns (int256) {
        Token memory token = TokenHandler.getUnderlyingToken(currencyId);
        // This will be true if the the token is "NonMintable" meaning that it does not have
        // an underlying token, only an asset token
        if (token.decimals == 0) token = TokenHandler.getAssetToken(currencyId);

        return token.convertToInternal(
            IStrategyVault(vault).convertStrategyToUnderlying(account, strategyTokens, maturity)
        );
    }

    /// @notice Returns the value in asset cash of a given amount of pool share
    function getCashValueOfShare(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        address account,
        uint256 vaultShares
    ) internal view returns (int256 assetCashValue) {
        if (vaultShares == 0) return 0;
        (uint256 assetCash, uint256 strategyTokens) = getPoolShare(vaultState, vaultShares);
        int256 underlyingInternalStrategyTokenValue = _getStrategyTokenValueUnderlyingInternal(
            vaultConfig.borrowCurrencyId, vaultConfig.vault, account, strategyTokens, vaultState.maturity
        );

        // Converts underlying strategy token value to asset cash
        assetCashValue = vaultConfig.assetRate
            .convertFromUnderlying(underlyingInternalStrategyTokenValue)
            .add(assetCash.toInt());
    }
}