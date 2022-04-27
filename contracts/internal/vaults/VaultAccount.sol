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

    /**
     * @notice Settles a vault account that has a position in a matured vault. This clears
     * the fCash balance off both the vault account and the vault state, crediting back to
     * the vault account any excess asset cash they have accrued since the settlement.
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param blockTime current block time
     */
    function _settleVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal {
        // These conditions mean that the vault account does not require settlement
        if (blockTime < vaultAccount.maturity || vaultAccount.maturity == 0) return;

        VaultState memory vaultState = vaultConfig.getVaultState(vaultAccount.maturity);

        // A vault must be fully settled for an account to settle. Most vaults should be able to settle
        // to be fully settled before maturity. However, some vaults may expect fCash to have matured before
        // they can settle (i.e. some vaults may be trading between two fCash currencies). Those vaults must
        // be settled within 24 hours of maturity expiration and before the staked nToken unstaking window begins.
        // For accounts that are within these vaults, they will face a period of time (< 24 hours) where they cannot
        // exit until the vault is settled. Vault settlement should be permissionless so this should not create
        // significant issues.
        require(vaultState.isFullySettled, "Vault not settled");

        // Returns the current settlement rate to convert between cash and fCash. Will write this
        // to storage if it does not exist yet.
        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            blockTime
        );

        // This is the same sign as totalAssetCash (most likely positive). If for some reason there is a negative
        // totalAssetCash here and the vault is fully settled it means that the nToken insurance fund has likely
        // been cleaned out. The transaction will likely revert since we do not allow vaultAccounts to carry a negative
        // cash balance. There would be no reason for an account to want to exit a vault where they are insolvent.
        int256 accountShareOfAssetCash = vaultState.totalAssetCash.mul(vaultAccount.fCash).div(vaultState.totalfCash);
        // This is a negative number
        int256 assetCashToRepayfCash = settlementRate.convertFromUnderlying(vaultAccount.fCash);

        // Update the vault state to account
        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(accountShareOfAssetCash);
        vaultState.totalfCash = vaultState.totalAssetCash.sub(vaultAccount.fCash);
        vaultConfig.setVaultState(vaultState);

        // Update the vault account in memory
        vaultAccount.fCash = 0;
        vaultAccount.maturity = 0;
        vaultAccount.cashBalance = vaultAccount.cashBalance.add(accountShareOfAssetCash).add(assetCashToRepayfCash);

        // At this point, the account has cleared its fCash balance on the vault and can re-enter a new vault maturity.
        // In all likelihood, it still has some balance of vaultShares on the vault. If it wants to re-enter a vault
        // these shares will be considered as part of its netAssetValue for its leverage ratio (along with whatever
        // cash balance has accrued here). If it wants to exit its profits, it can withdraw its cash balance and sell
        // whatever vault shares it has left.
    }

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
     * @notice Allows an account to exit a vault term prematurely by lending fCash
     * - Check that fCash is less than or equal to account's position
     * - Either:
     *      Lend fCash on the market, calculate the cost to do so
     *      Deposit cash,  calculate the cost to do so
     * - Net off the cost to lend fCash with the account's collateral position
     * - Return the cost to exit the position (normally negative but theoretically can
     *   be positive if holding a collateral buffer > 100%)
     * - Clear the account's fCash and collateral position
     */
    function _lendToExitVault(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        int256 fCash,
        uint256 maxLendRate,
        uint256 blockTime
    ) internal returns (int256 assetCashCostToExit) {
        // checkAndSettleVault(vaultConfig, vaultState, blockTime);
        // // Netting off the fCash cannot go above zero (we don't want the account to over lend their position)
        // require(fCash > 0 && vaultAccount.fCashShare.add(fCash) <= 0);
        // {
        //     // You can only exit the current vault or the next vault term.
        //     uint256 nextTerm = vaultState.currentMaturity.add(vaultConfig.termLengthInDays.mul(Constants.DAY));
        //     require(
        //         vaultAccount.fCashMaturity == vaultState.currentMaturity ||
        //         vaultAccount.fCashMaturity == nextTerm
        //     );
        // }

        // (
        //     int256 assetCashCostToLend,
        //     AssetRateParameters memory assetRate
        // ) = _executeTrade(
        //     vaultConfig.borrowCurrencyId,
        //     vaultAccount.fCashMaturity,,
        //     fCash, // positive amount of fCash to lend (checked above)
        //     maxLendRate,
        //     blockTime
        // );

        // // TODO: the account has a claim on the total vault cash balance in addition to any
        // // cash balance in their account. This cash balance is here from on settlements
        // int256 vaultCashBalanceClaim = vaultState.cashBalance.mul(vaultAccount.fCashShare).div(vaultState.currentfCashBalance);

        // if (assetCashCostToLend == 0) {
        //     // If the cost to lend is zero it signifies that there was insufficient liquidity,
        //     // therefore we will just deposit the asset cash instead of lending. This will be
        //     // sufficient to cover the fCash debt, and in all likelihood the account will accrue
        //     // some amount assetCash interest over the amount they owe.
        //     assetCashCostToLend = assetRate.convertFromUnderlying(fCash).neg();
        //     // Net off from the cost to lend the amount the account has already deposited
        //     assetCashCostToExit = assetCashCostToLend.add(vaultAccount.cashBalance);
        //     // In this case we just mark that the account has deposited some amount of asset cash
        //     // against their fCash. Once maturity occurs we will mark a settlement rate and the
        //     // account can fully exit their position by netting off the fCash.
        //     vaultAccount.cashBalance = assetCashCostToLend;
        // } else {
        //     int256 remainingfCash = vaultAccount.fCashShare.add(fCash);

        //     if (remainingfCash == 0) {
        //         // If fully exiting the fCash position then we can use all of the deposit and
        //         // clear the maturity
        //         assetCashCostToExit = assetCashCostToLend.add(vaultAccount.cashBalance);
        //         vaultAccount.fCashShare = 0;
        //         vaultAccount.fCashMaturity = 0;
        //         vaultAccount.cashBalance = 0;
        //     } else {
        //         // If partially exiting the fCash position then we can apply a prorata portion
        //         // of the deposit against the cost to exit.
        //         assetCashDepositShare = vaultAccount.cashBalance.mul(remainingfCash).div(vaultAccount.fCashShare);
        //         assetCashCostToExit = assetCashCostToLend.add(assetCashDepositShare);

        //         vaultAccount.assetCashDeposit = vaultAccount.assetCashDeposit.sub(assetCashDepositShare);
        //         vaultAccount.fCashShare = remainingfCash;
        //     }

        //     // Modify the vault state since were are changing the fCash balance here.
        //     vaultState.currentfCashBalance = vaultState.currentfCashBalance.add(fCash);
        // }
        
        // // If assetCashCostToExit < 0 then the account will deposit that amount of cash into
        // // the vault, if the assetCashCostToExit > 0 then the account will withdraw their profits
        // // from the vault.
        // vaultState.cashBalance = vaultState.cashBalance.sub(assetCashCostToExit);
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
