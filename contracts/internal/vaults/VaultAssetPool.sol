// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

/**
 * @notice VaultAssetPool holds a combination of asset cash and strategy tokens on behalf of the
 * vault accounts. When accounts enter or exit the pool they receive vault shares corresponding to
 * at the ratio of asset cash to strategy tokens in their maturity pool. A maturity pool may hold
 * asset cash during a risk-off event or as it unwinds to repay its debt at maturity.
 */
library VaultAssetPool {

    struct MaturityPool {
        uint80 totalVaultShares;
        uint80 totalAssetCash;
        uint80 totalStrategyTokens;
    }

    /**
     * @notice Exits a maturity pool for an account given the shares to redeem. Asset cash will be credited
     * to tempCashBalance.
     * @param vaultAccount will use the maturity on the vault account to choose which pool to exit
     * @param vaultSharesToRedeem amount of shares to redeem
     * @return strategyTokensWithdrawn amount of strategy tokens withdrawn from the pool
     */
    function exitMaturityPool(
        VaultAccount memory vaultAccount,
        uint256 vaultSharesToRedeem
    ) internal returns (uint256 strategyTokensWithdrawn) {
        MaturityPool memory maturityPool = getMaturityPool(vaultAccount.maturity);
        vaultAccount.vaultShares = vaultAccount.vaultShares.sub(vaultSharesToRedeem);

        // Calculate the claim on cash tokens and strategy tokens
        uint256 assetCashWithdrawn;
        (assetCashWithdrawn, strategyTokensWithdrawn) = _getPoolShare(maturityPool, vaultSharesToRedeem);

        // Remove tokens from the maturityPool and set the storage
        maturityPool.totalAssetCash = maturityPool.totalAssetCash.sub(assetCashWithdrawn);
        maturityPool.totalStrategyTokens = maturityPool.totalStrategyTokens.sub(strategyTokensWithdrawn);
        maturityPool.totalVaultShares = maturityPools.totalVaultShares.sub(vaultSharesToRedeem);
        setMaturityPool(vaultAccount.maturity, maturityPool);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(assetCashWithdrawn);
    }

    /**
     * @notice Enters a maturity pool (including depositing cash and minting vault shares). If the maturity
     * on the account is changing, then we will first redeem from the old maturity pool and move the account's
     * positions to the new maturity pool.
     * @param vaultAccount will update maturity and reduce tempCashBalance to zero
     * @param vaultConfig vault config
     * @param maturity the new maturity to set on the vault account
     * @param vaultData calldata to pass to the vault
     */
    function enterMaturityPool(
        VaultAccount memory vaultAccount,
        VaultConfig vaultConfig,
        uint256 maturity,
        bytes calldata vaultData
    ) internal {
        require(vaultAccount.tempCashBalance > 0);

        if (vaultAccount.maturity != maturity) {
            exitMaturityPool(vaultAccount, vaultAccount.vaultShares);
            vaultAccount.maturity = maturity;
        }

        MaturityPool memory maturityPool = getMaturityPool(vaultAccount.maturity);
        uint256 assetCashWithheld;
        if (maturityPool.totalAssetCash > 0) {
            // TODO: should we even allow this to happen?
            uint256 totalValueOfPool = vaultConfig.getCashValueOfStrategyTokens(
                maturityPool.totalStrategyTokens
            ).add(vault.totalAssetCash);

            // NOTE: this valuation assumes zero slippage, in reality that probably won't be the case.
            // Generally, pools should not be in this position unless something strange has happened
            // but if an account does enter here then they will take a penalty on the vault shares they
            // receive.
            uint256 totalValueOfDeposits = vaultConfig.getCashValueOfStrategyTokens(
                vaultAccount.tempStrategyTokens
            ).add(vaultAccount.tempCashBalance);

            assetCashWithheld = totalValueOfDeposits.mul(maturityPool.totalAssetCash).div(totalValueOfPool);
        }

        // If this becomes negative, it's possible that an account cannot roll into a new maturity when the new
        // maturity is holding cash tokens. It would need to redeem additional strategy tokens in order to have
        // sufficient cash to enter the new maturity. This is will only happen for accounts that are rolling maturities
        // with active strategy token positions (not entering maturities for the first time).
        uint256 cashToTransfer = uint256(vaultAccount.tempCashBalance).sub(assetCashWithheld);
        uint256 strategyTokensDeposit = vaultAccount.tempStrategyTokens;
        vaultAccount.tempCashBalance = 0;
        vaultAccount.tempStrategyTokens = 0;

        // This will transfer the cash amount to the vault and mint strategy tokens which will be transferred
        // to the current contract.
        strategyTokensDeposit = strategyTokensDeposit.add(vaultConfig.deposit(cashToTransfer, vaultData));
        _mintVaultSharesInMaturity(maturityPool, maturity, assetCashWithheld, strategyTokensDeposit);
    }

    /** @notice Updates maturity vault shares in storage.  */
    function _mintVaultSharesInMaturity(
        MaturityPool memory pool,
        uint256 maturity,
        uint256 assetCashDeposited,
        uint256 strategyTokensDeposited
    ) private returns (uint256 vaultSharesMinted) {
        if (pool.totalVaultShares == 0) {
            vaultSharesMinted = strategyTokensDeposited;
        } else {
            vaultSharesMinted = strategyTokensDeposited.mul(pool.totalVaultShares).div(pool.totalStrategyTokens);
        }

        pool.totalAssetCash = pool.totalAssetCash.add(assetCashDeposited);
        pool.totalStrategyTokens = pool.totalStrategyTokens.add(strategyTokensDeposited);
        pool.totalVaultShares = pool.totalVaultShares.add(vaultSharesMinted);
        setMaturityPool(maturity, pool);
    }

    /** @notice Returns the component amounts for a given amount of vaultShares */
    function getPoolShare(
        MaturityPool memory maturityPool,
        uint256 vaultShares
    ) internal pure returns (
        uint256 assetCash,
        uint256 strategyTokens
    ) {
        assetCash = (vaultShares * maturityPool.totalAssetCash) / maturityPool.totalVaultShares;
        strategyTokens = (vaultShares * maturityPool.totalStrategyTokens) / maturityPool.totalVaultShares;
    }

    /** @notice Returns the value in asset cash of a given amount of pool share */
    function getCashValueOfShare(
        VaultConfig memory vaultConfig,
        MaturityPool memory maturityPool,
        uint256 vaultShares
    ) internal view returns (int256 assetCashValue) {
        if (vaultShares == 0) return 0;
        (uint256 assetCash, uint256 strategyTokens) = getPoolShare(maturityPool, vaultShares);
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
        assetCashValue = SafeInt256.toUint(vaultConfig.assetRate.convertFromUnderlying(
            // Convert the underlying value to internal precision
            SafeInt.toInt(underlyingValue)
                .mul(Constants.INTERNAL_TOKEN_PRECISION).div(vaultConfig.assetRate.underlyingPrecision);
        ))).add(assetCash);
    }

}