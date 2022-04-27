// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

library VaultAccount {
    /// @notice Returns a single account's vault position
    function getVaultAccount(address account, address vaultAddress)
        internal
        view
        returns (VaultAccount memory vaultAccount)
    {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultAddress];

        vaultAccount.fCash = s.fCash;
        vaultAccount.cashBalance = s.cashBalance;
        vaultAccount.maturity = s.maturity;
    }

    /// @notice Sets a single account's vault position in storage
    function setVaultAccount(
        address account,
        address vaultAddress,
        VaultAccount memory vaultAccount
    ) internal {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultAddress];

        // Individual accounts cannot have a negative cash balance
        require(0 <= vaultAccount.cashBalance && vaultAccount.cashBalance <= type(int88).max); // dev: cash balance overflow
        // Individual accounts cannot have a positive fCash balance
        require(type(int88).min <= vaultAccount.fCash && vaultAccount.fCash <= 0); // dev: fCash overflow
        require(vaultAccount.maturity <= type(uint32).max); // dev: maturity overflow

        s.fCash = int88(vaultAccount.fCash);
        s.cashBalance = int88(vaultAccount.cashBalance);
        s.maturity = uint32(vaultAccount.maturity);
    }

    // /**
    //  * @notice If the vault account is in the past, then settle it.
    //  */
    // function _settleVaultAccount(
    //     VaultAccount memory vaultAccount,
    //     VaultConfig memory vaultConfig,
    //     uint256 blockTime
    // ) private {
    //     // Each of these conditions mean that the vault account does not require settlement
    //     if (
    //         vaultAccount.maturity > blockTime ||
    //         vaultAccount.maturity == 0 ||
    //         vaultAccount.fCash == 0
    //     ) return;

    //     // Returns the current settlement rate to convert between cash and fCash. Will write this
    //     // to storage if it does not exist yet.
    //     AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
    //         vaultConfig.borrowCurrencyId,
    //         vaultAccount.maturity,
    //         blockTime
    //     );

    //     VaultState memory vaultStateAtMaturity = VaultConfiguration.getVaultState(
    //         vaultConfig.vaultAddress,
    //         vaultAccount.maturity
    //     );
    //     require(vaultStateAtMaturity.isFullySettled, "Vault not settled");

    //     int256 accountShareOfAssetCash = vaultStateAtMaturity.totalAssetCash
    //         .mul(vaultAccount.fCash)
    //         .div(vaultStateAtMaturity.totalfCash);
    //     int256 assetCashToRepayfCash = settlementRate.convertFromUnderlying(vaultAccount.fCash);

    //     vaultAccount.cashBalance = vaultAccount.cashBalance
    //         .add(accountShareOfAssetCash)
    //         .add(assetCashToRepayfCash); // this is negative
        
    //     vaultState.totalAssetCash = vaultState.totalAssetCash.sub(accountShareOfAssetCash);
    //     vaultState.totalfCash = vaultState.totalAssetCash.sub(accountShareOfAssetCash);
    // }

    /**
     * @notice Borrows fCash to enter a vault, checks the leverage ratio and pays the nToken fee
     * @dev Updates vault fCash in storage, updates vaultAccount in memory
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param maturity the maturity to enter for the vault
     * @param fCash amount of fCash to borrow from the market, must be negative
     * @param maxBorrowRate maximum annualized rate to pay for the borrow
     * @param blockTime current block time
     */
    function _borrowIntoVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        int256 fCash,
        uint256 maxBorrowRate,
        uint256 blockTime
    ) private {
        require(fCash < 0); // dev: fcash must be negative
        VaultState memory vaultState = getVaultState(vaultConfig.vault, maturity);

        // Cannot enter a vault if it is in a shortfall
        require(vaultState.cashBalance >= 0); // dev: in shortfall
        // The vault account can only be increasing their position or not have one set. If they are
        // at a different maturity they must exit first. The vaultState maturity will always be the
        // current maturity because we check if it must be settled first.
        require(vaultAccount.maturity == 0 || vaultAccount.maturity == maturity);

        // All of the cash borrowed will go to the vault. Additional collateral and fees required
        // will be calculated below and taken from the account's external balances.
        (assetCashBorrowed, assetRate) = _executeTrade(
            vaultConfig.borrowCurrencyId,
            maturity,
            fCash,
            maxBorrowRate,
            blockTime
        );
        require(assetCashBorrowed > 0, "Borrow failed");

        // Since the nToken fee depends on the leverage ratio, we calculate the leverage ratio
        // assuming the worst case scenario. Will adjust the fee properly at the end
        int256 maxNTokenFee = vaultConfig.getNTokenFee(vaultConfig.maxLeverageRatio, fCash);

        // Update the account and vault state to account for the borrowing
        vaultState.totalfCash = vaultState.totalfCash.add(fCash);
        vaultAccount.fCash = vaultAccount.fCash.add(fCash);
        vaultAccount.maturity = maturity;
        vaultAccount.cashBalance = vaultAccount.cashBalance.add(assetCashBorrowed).sub(maxNTokenFee);

        // Ensure that we are above the minimum borrow size. Accounts smaller than this are not profitable
        // to unwind if we need to liquidate.
        require(vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");
        require(vaultState.totalfCash.neg() <= vaultConfig.maxVaultBorrowSize, "Max Vault Size");

        // Leverage ratio is calculated as a ratio of the total borrowing to net assets
        int256 leverageRatio = _calculateLeverage(vaultAccount, vaultConfig, assetRate);
        require(leverageRatio <= vaultConfig.maxLeverageRatio, "Excess leverage");

        int256 nTokenFee = vaultConfig.getNTokenFee(leverageRatio, fCash);
        // This will mint nTokens assuming that the fee will be paid. If the fee is not paid the txn will revert.
        nTokenStaked.payFeeToStakedNToken(vaultConfig.borrowCurrencyId, nTokenFee, blockTime);
        vaultAccount.cashBalance = vaultAccount.cashBalance.add(maxNTokenFee).sub(nTokenFee);

        // Done modifying the vault state at this point.
        VaultConfiguration.setVaultState(vaultConfig.vault, vaultState);
    }

    /**
     * @notice Calculates the leverage ratio of the account given how much assetCashDeposit
     * and how much fee to pay to the nToken
     */
    function _calculateLeverage(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        AssetRateParameters memory assetRate
    ) private view returns (int256 leverageRatio) {
        // The net asset value includes all value in cash and vault shares in underlying internal
        // precision minus the total amount borrowed
        int256 netAssetValue = assetRate.convertToUnderlying(vaultAccount.cashBalance)
            .add(vaultConfig.underlyingValueOf(vaultAccount.account))
            // We do not discount fCash to present value so that we do not introduce interest
            // rate risk in this calculation.
            .add(vaultAccount.fCash)

        // Can never have negative value of assets
        require(netAssetValue > 0);

        // Leverage ratio is: (borrowValue / netAssetValue)
        leverageRatio = vaultAccount.fCash.neg().divInRatePrecision(netAssetValue);
    }

    /**
     * @notice Executes a trade on the AMM.
     * @param currencyId id of the vault borrow currency
     * @param maturity maturity to lend or borrow at
     * @param netfCashToAccount positive if lending, negative if borrowing
     * @param rateLimit 0 if there is no limit, otherwise is a slippage limit
     * @param blockTime current time
     * @return netAssetCash amount of cash to credit to the account
     * @return assetRate conversion rate between asset cash and underlying
     */
    function _executeTrade(
        uint16 currencyId,
        uint256 maturity
        int256 netfCashToAccount
        uint256 rateLimit,
        uint256 blockTime
    ) internal returns (int256, AssetRateParameters memory) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupStateful(currencyId);
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(cashGroup.maxMarketIndex, maturity, blockTime);
        require(!isIdiosyncratic);

        MarketParameters memory market;
        // NOTE: this loads the market in memory
        cashGroup.loadMarket(market, marketIndex, false, blockTime);
        int256 assetCash = market.executeTrade(
            cashGroup,
            fCash,
            market.maturity.sub(blockTime),
            marketIndex
        );

        if (fCash < 0 && rateLimit > 0) {
            require(market.lastImpliedRate <= rateLimit);
        } else {
            require(market.lastImpliedRate >= rateLimit);
        }

        return (assetCash, cashGroup.assetRate);
    }
}
