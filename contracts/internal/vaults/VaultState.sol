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
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
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
    using VaultConfiguration for VaultConfig;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    function getVaultState(
        address vault,
        uint256 maturity
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vault][maturity];

        vaultState.maturity = maturity;
        // fCash debts are represented as negative integers on the stack
        vaultState.totalfCashRequiringSettlement = -int256(int80(s.totalfCashRequiringSettlement));
        vaultState.totalfCash = -int256(int80(s.totalfCash));
        vaultState.isFullySettled = s.isFullySettled;
        vaultState.accountsRequiringSettlement = s.accountsRequiringSettlement;

        vaultState.totalAssetCash = s.totalAssetCash;
        vaultState.totalStrategyTokens = s.totalStrategyTokens;
        vaultState.totalVaultShares = s.totalVaultShares;
    }

    function setVaultState(
        VaultState memory vaultState,
        address vault
    ) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vault][vaultState.maturity];

        require(vaultState.accountsRequiringSettlement <= type(uint32).max); // dev: accounts settlement overflow
        // There is always less totalfCashRequiringSettlement than totalfCash (both are negative)
        require(vaultState.totalfCash <= vaultState.totalfCashRequiringSettlement); 

        s.totalfCashRequiringSettlement= safeUint80(vaultState.totalfCashRequiringSettlement.neg());
        s.totalfCash = safeUint80(vaultState.totalfCash.neg());
        s.isFullySettled = vaultState.isFullySettled;
        s.accountsRequiringSettlement = uint32(vaultState.accountsRequiringSettlement);

        s.totalAssetCash = safeUint80(vaultState.totalAssetCash);
        s.totalStrategyTokens = safeUint80(vaultState.totalStrategyTokens);
        s.totalVaultShares = safeUint80(vaultState.totalVaultShares);
    }

    /**
     * @notice Exits a maturity pool for an account given the shares to redeem. Asset cash will be credited
     * to tempCashBalance.
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

        // Calculate the claim on cash tokens and strategy tokens
        uint256 assetCashWithdrawn;
        (assetCashWithdrawn, strategyTokensWithdrawn) = getPoolShare(vaultState, vaultSharesToRedeem);

        // Remove tokens from the maturityPool and set the storage
        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(assetCashWithdrawn);
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.sub(strategyTokensWithdrawn);
        vaultState.totalVaultShares = vaultState.totalVaultShares.sub(vaultSharesToRedeem);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(SafeInt256.toInt(assetCashWithdrawn));
    }

    /**
     * @notice Enters a maturity pool (including depositing cash and minting vault shares). If the maturity
     * on the account is changing, then we will first redeem from the old maturity pool and move the account's
     * positions to the new maturity pool.
     * @param vaultAccount will update maturity and reduce tempCashBalance to zero
     * @param vaultConfig vault config
     * @param vaultState vault state for the maturity we are entering
     * @param vaultData calldata to pass to the vault
     */
    function enterMaturityPool(
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        bytes calldata vaultData
    ) internal {
        require(vaultAccount.tempCashBalance > 0);

        uint256 strategyTokenDeposit;
        if (vaultAccount.maturity != vaultState.maturity) {
            // If the vault account is in an old maturity, we exit that pool move their shares
            // into the new maturity and update their account
            VaultState memory oldVaultState = getVaultState(vaultConfig.vault, vaultAccount.maturity);
            strategyTokenDeposit = exitMaturityPool(oldVaultState, vaultAccount, vaultAccount.vaultShares);
            setVaultState(oldVaultState, vaultConfig.vault);

            vaultAccount.maturity = vaultState.maturity;
            vaultAccount.vaultShares = 0;
        }

        uint256 assetCashWithheld;
        if (vaultState.totalAssetCash > 0 && vaultAccount.vaultShares > 0) {
            // TODO: should we even allow this to happen?
            uint256 totalValueOfPool = SafeInt256.toUint(getCashValueOfShare(vaultState, vaultConfig, vaultState.totalVaultShares));

            // NOTE: this valuation assumes zero slippage, in reality that probably won't be the case.
            // Generally, pools should not be in this position unless something strange has happened
            // but if an account does enter here then they will take a penalty on the vault shares they
            // receive.
            uint256 totalValueOfDeposits = SafeInt256.toUint(getCashValueOfShare(vaultState, vaultConfig, vaultAccount.vaultShares));

            assetCashWithheld = totalValueOfDeposits.mul(vaultState.totalAssetCash).div(totalValueOfPool);
        }

        // If this becomes negative, it's possible that an account cannot roll into a new maturity when the new
        // maturity is holding cash tokens. It would need to redeem additional strategy tokens in order to have
        // sufficient cash to enter the new maturity. This is will only happen for accounts that are rolling maturities
        // with active strategy token positions (not entering maturities for the first time).
        int256 cashToTransfer = vaultAccount.tempCashBalance.sub(SafeInt256.toInt(assetCashWithheld));
        vaultAccount.tempCashBalance = 0;

        // This will transfer the cash amount to the vault and mint strategy tokens which will be transferred
        // to the current contract.
        strategyTokenDeposit = strategyTokenDeposit.add(vaultConfig.deposit(cashToTransfer, vaultData));
        vaultAccount.vaultShares = _mintVaultSharesInMaturity(vaultState, assetCashWithheld, strategyTokenDeposit);
    }

    /** @notice Updates maturity vault shares in storage.  */
    function _mintVaultSharesInMaturity(
        VaultState memory vaultState,
        uint256 assetCashDeposited,
        uint256 strategyTokensDeposited
    ) private pure returns (uint256 vaultSharesMinted) {
        if (vaultState.totalVaultShares == 0) {
            vaultSharesMinted = strategyTokensDeposited;
        } else {
            vaultSharesMinted = strategyTokensDeposited.mul(vaultState.totalVaultShares).div(vaultState.totalStrategyTokens);
        }

        vaultState.totalAssetCash = vaultState.totalAssetCash.add(assetCashDeposited);
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.add(strategyTokensDeposited);
        vaultState.totalVaultShares = vaultState.totalVaultShares.add(vaultSharesMinted);
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

    /** @notice Returns the value in asset cash of a given amount of pool share */
    function getCashValueOfShare(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        uint256 vaultShares
    ) internal view returns (int256 assetCashValue) {
        if (vaultShares == 0) return 0;
        (uint256 assetCash, uint256 strategyTokens) = getPoolShare(vaultState, vaultShares);
        uint256 underlyingValue = IStrategyVault(vaultConfig.vault).convertStrategyToUnderlying(strategyTokens);
        
        // Generally speaking, asset cash held in the maturity pool is held in escrow for repaying the
        // vault debt. This may not always be the case, vaults may hold asset cash during a risk-off event
        // where they trade strategy tokens back to asset cash during a potentially volatile time. In both
        // cases we do not use asset cash held in a maturity pool to net off against outstanding fCash debt.
        // If we did, this would reduce the leverage ratio of the vault. However, it's possible that asset
        // cash may re-enter a vault as strategy tokens once the volatility has passed which would then increase
        // the leverage ratio of the vault -- we don't want it to increase past its maximum. During settlement,
        // accounts cannot re-enter the vault anyway so a higher leverage ratio should not have an effect. The
        // leverage ratio will also fluctuate less to changes in strategy token value when asset cash is
        // held in the pool.
        assetCashValue = vaultConfig.assetRate.convertFromUnderlying(
            // Convert the underlying value to internal precision
            SafeInt256.toInt(underlyingValue)
                .mul(Constants.INTERNAL_TOKEN_PRECISION).div(vaultConfig.assetRate.underlyingDecimals)
        ).add(SafeInt256.toInt(assetCash));
    }

    function safeUint80(int256 x) internal pure returns (uint80) {
        require(0 <= x && x < int256(type(uint80).max));
        return uint80(uint256(x));
    }

    function safeUint80(uint256 x) internal pure returns (uint80) {
        require(x < uint256(type(uint80).max));
        return uint80(x);
    }

}