
library VaultAssetPool {

    struct MaturityPool {
        uint80 totalVaultShares;
        uint80 totalAssetCash;
        uint80 totalStrategyTokens;
    }

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

        // TODO: this should redeem to underlying or asset and then transfer to the vault
        strategyTokensDeposit = strategyTokensDeposit.add(vaultConfig.deposit(cashToTransfer, vaultData));
        _mintVaultSharesInMaturity(maturityPool, maturity, assetCashWithheld, strategyTokensDeposit);
    }

    function _mintVaultSharesInMaturity(
        MaturityPool memory pool,
        uint256 maturity,
        uint256 assetCashDeposited,
        uint256 strategyTokensDeposited
    ) private returns (uint256 vaultSharesMinted) {
        if (pool.totalVaultShares == 0) {
            vaultSharesMinted = strategyTokensDeposited;
        } else {
            vaultSharesMinted = strategyTokensDeposited
                .mul(pool.totalVaultShares)
                .div(pool.totalStrategyTokens);
        }

        pool.totalAssetCash = pool.totalAssetCash.add(assetCashDeposited);
        pool.totalStrategyTokens = pool.totalStrategyTokens.add(strategyTokensDeposited);
        pool.totalVaultShares = pool.totalVaultShares.add(vaultSharesMinted);
        setMaturityPool(maturity, pool);
    }

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

    function getCashValueOfShare(
        VaultConfig memory vaultConfig,
        uint256 strategyTokens
    ) internal view returns (uint256 assetCashValue) {
        if (strategyTokens == 0) return 0;

        int256 underlyingValue = SafeInt256.toInt(
            IStrategyVault(vaultConfig.vault).convertStrategyToUnderlying(strategyTokens)
        );
        
        assetCashValue = SafeInt256.toUint(vaultConfig.assetRate.convertFromUnderlying(
            // Convert the underlying value to internal precision
            underlyingValue
                .mul(Constants.INTERNAL_TOKEN_PRECISION)
                .div(vaultConfig.assetRate.underlyingPrecision);
        ));
    }

}