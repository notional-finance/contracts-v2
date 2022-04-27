// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

library VaultFlags {
    uint16 internal constant ENABLED            = 1 << 0;
    uint16 internal constant ALLOW_REENTER      = 1 << 1;
    uint16 internal constant IS_INSURED         = 1 << 2;
    uint16 internal constant CAN_INITIALIZE     = 1 << 3;
    uint16 internal constant ACCEPTS_COLLATERAL = 1 << 4;
}

library VaultConfiguration {

    function getVaultConfig(
        address vaultAddress
    ) internal view returns (VaultConfig memory vaultConfig) {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfigStorage storage s = store[vaultAddress];

        vaultConfig.flags = s.flags;
        vaultConfig.borrowCurrencyId = s.borrowCurrencyId;
        vaultConfig.maxVaultBorrowSize = s.maxVaultBorrowSize;
        vaultConfig.minAccountBorrowSize = s.minAccountBorrowSize.mul(Constants.INTERNAL_TOKEN_PRECISION);
        vaultConfig.riskFactor = s.riskFactor;
        vaultConfig.termLengthSeconds = s.termLengthInDays.mul(Constants.DAYS);
        vaultConfig.nTokenFeeBPS = s.nTokenFee5BPS.mul(Constants.BASIS_POINT * 5);
        vaultConfig.collateralBufferPercent = s.collateralBufferPercent;
    }

    function setVaultConfig(
        address vaultAddress,
        VaultConfigStorage memory vaultConfig
    ) internal {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        store[vaultAddress] = vaultConfig;
    }

    function getVaultState(
        address vaultAddress
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => VaultStateStorage) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultAddress];

        vaultState.cashBalance = s.cashBalance;
        vaultState.currentfCashBalance = s.currentfCashBalance,
        vaultState.currentMaturity = s.currentMaturity,
        vaultState.nextTermfCashBalance = s.nextTermfCashBalance,
    }

    function setVaultState(
        address vaultAddress,
        VaultState memory vaultState
    ) internal {
        mapping(address => VaultStateStorage) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultAddress];

        require(type(int88).min <= vaultState.cashBalance && vaultState.cashBalance <= type(int88).max); // dev: cash balance overflow
        require(type(int88).min <= vaultState.currentfCashBalance && vaultState.currentfCashBalance <= type(int88).max); // dev: cash balance overflow
        require(type(int88).min <= vaultState.nextTermfCashBalance && vaultState.nextTermfCashBalance <= type(int88).max); // dev: next term fcash balance
        require(vaultState.currentMaturity <= type(uint32).max); // dev: current maturity

        s.cashBalance = int88(vaultState.cashBalance);
        s.currentfCashBalance = int88(vaultState.currentfCashBalance);
        s.currentMaturity = uint32(vaultState.currentMaturity);
        s.nextTermfCashBalance = int88(vaultState.nextTermfCashBalance);
    }

    function getVaultAccount(
        address account,
        address vaultAddress
    ) internal view returns (VaultAccount memory vaultAccount) {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage.getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultAddress];

        vaultAccount.fCashShare = s.fCashShare;
        vaultAccount.cashBalance = s.cashBalance;
        vaultAccount.maturity = s.maturity;
    }

    function setVaultAccount(
        address account,
        address vaultAddress,
        VaultAccount memory vaultAccount
    ) internal {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage.getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultAddress];

        require(type(int88).min <= vaultAccount.cashBalance && vaultAccount.cashBalance <= type(int88).max); // dev: cash balance overflow
        require(type(int88).min <= vaultAccount.fCashShare && vaultAccount.fCashShare <= type(int88).max); // dev: fCash overflow
        require(vaultAccount.maturity <= type(uint32).max); // dev: maturity overflow

        s.fCashShare = int88(vaultAccount.fCashShare);
        s.cashBalance = int88(vaultAccount.cashBalance);
        s.maturity = uint32(vaultAccount.maturity);
    }

    /**
     * @notice Returns that status of a given flagID from VaultFlags
     */
    function getFlag(
        VaultConfig memory vaultConfig
        uint16 flagID
    ) internal pure returns (bool) {
        return (vaultConfig.flags & flagID) == flagID;
    }

    /**
     * @notice Returns the current maturity based on the term length modulo the
     * current time.
     * @param vaultConfig vault configuration
     * @param blockTime current block time
     * @return the current maturity for the vault given the block time
     */
    function getCurrentMaturity(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal pure returns (uint256) {
        uint256 blockTimeUTC0 = DateTime.getTimeUTC0(blockTime);
        uint256 termLengthInSeconds = (vaultConfig.termLengthInDays * Constants.DAY);
        // NOTE: termLengthInDays cannot be 0
        uint256 offset = blockTimeUTC0 % termLengthInSeconds;

        return blockTimeUTC0.sub(offset).add(termLengthInSeconds);
    }

    /**
     * @notice Settles the current vault fCash balance by netting off the held cash balance
     * and fCash balance at current settlement rates. The net remaining fCash balance will
     * be returned.
     * @param vaultConfig vault configuration
     * @param vaultState current state of the vault, if settled this will be modified in memory
     * @param blockTime current block time
     * @return didSettle will be true if the vault was settled
     */
    function checkAndSettleVault(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 blockTime
    ) internal (bool didSettle) {
        // Do not settle before maturity
        if (blockTime < vaultState.currentMaturity) return (false, 0);
        didSettle = true;

        // Returns the current settlement rate to convert between cash and fCash. Will write this
        // to storage if it does not exist yet.
        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            vaultState.currentMaturity,
            blockTime
        );

        // After converting the fCash cash balance (in underlying terms) to the settled asset cash
        // terms we can net it off. If netCash > 0 then we can return some cash to vault holders (this
        // is likely to be the case from cToken interest accrued). If netCash < 0 then we have a shortfall
        // and staked nToken holders need to redeem.

        // Setting of all these values modifies memory only
        vaultState.cashBalance = vaultState.cashBalance
            .add(settlementRate.convertFromUnderlying(vaultState.currentfCashBalance));
        vaultState.currentfCashBalance = vaultState.nextTermfCashBalance;
        vaultState.nextTermfCashBalance = 0;
        vaultState.currentMaturity = getCurrentMaturity(vaultConfig, blockTime);
    }

    /**
     * @notice Returns the maximum capacity a vault has to borrow. The formula for this is:
     * min(vaultConfig.maxVaultBorrowSize, nTokenPVUnderlying(stakedNToken.nTokenBalance) * 1e8 / riskFactor)
     */
    function getMaxBorrowSize(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 blockTime
    ) internal view returns (uint256 maxBorrowfCash) {
        // If riskFactor < 1e8 then the maxNTokenCapacity will be greater than the staked nToken
        // PV in underlying. If riskFactor > 1e8 then the max capacity will be less than the PV
        // of the staked nToken pool.
        uint256 maxNTokenCapacity = nTokenStaked.getStakedNTokenValueUnderlying(vaultConfig.borrowCurrencyId)
            .mul(1e8)
            .div(vaultConfig.riskFactor);
        
        // Gets the minimum value between the two amounts
        uint256 maxCapacity = vaultConfig.maxVaultBorrowSize < maxNTokenCapacity ?
            vaultConfig.maxVaultBorrowSize : 
            maxNTokenCapacity;

        if (maxCapacity <= vaultState.currentfCashBalance) {
            // It is possible that a vault goes over the max borrow size because nTokens can change
            // in value as interest rates change. If this is the case, we just don't allow any more
            // borrowing.
            return 0;
        } else {
            return maxCapacity.sub(vaultState.currentfCashBalance);
        }
    }

    function getPredictedMaxBorrowSize(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 blockTime
    ) internal view returns (uint256 maxBorrowfCash) {
        // TODO
    }

    /**
     * @notice Allows an account to enter a vault term. Will do the following:
     *  - Settle the vault so that it is in the current maturity
     *  - Check that the account is not in the vault in a different term
     *  - Check that the amount of fCash can be borrowed based on vault parameters
     *  - Borrow fCash from the vault's active market term
     *  - Calculate the netUnderlying = convertToUnderlying(netAssetCash)
     *  - Pay the required fee to the nToken
     *  - Calculate the amount of collateral required (fCash - netUnderlying) + collateralBuffer * netUnderlying + fee
     *  - Calculate the assetCashExternal to the vault (netAssetCash)
     *  - Store the account's fCash and collateral position
     *  - Store the vault's total fCash position
     */
    function enterCurrentVault(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 fCash,
        uint256 maxBorrowRate,
        uint256 blockTime
    ) private returns (
        int256 assetCashCollateralRequired,
        int256 assetCashToVault
    ) {
        checkAndSettleVault(vaultConfig, vaultState, blockTime);
        // Cannot enter a vault if it is in a shortfall
        require(vaultState.cashBalance >= 0); // dev: in shortfall
        // The vault account can only be increasing their position or not have one set. If they are
        // at a different maturity they must exit first. The vaultState maturity will always be the
        // current maturity because we check if it must be settled first.
        require(
            vaultAccount.maturity == 0 ||
            vaultAccount.maturity == vaultState.currentMaturity
        );

        // Ensure that the borrow amount fits into the required parameters
        require(
            vaultConfig.minAccountBorrowSize <= fCash && fCash <= getMaxBorrowSize(vaultConfig, vaultState, blockTime)
        );
        
        AssetRateParameters memory assetRate;
        // All of the cash borrowed will go to the vault. Additional collateral and fees required
        // will be calculated below and taken from the account's external balances.
        (
            assetCashToVault,
            assetRate
        ) = _executeTrade(
            vaultConfig.borrowCurrencyId,
            vaultState.currentMaturity,
            SafeInt256.toInt256(fCash).neg(), // negative fCash signifies borrowing
            maxBorrowRate,
            blockTime
        );
        require(assetCashToVault > 0);
        
        // The nToken fee is assessed on the principal borrowed. BPS are in "rate precision"
        int256 nTokenFee = assetCashAmount.mulInRatePrecision(vaultConfig.nTokenFeeBPS);
        // This will mint nTokens assuming that the fee will be paid. If the fee is not paid the txn will revert.
        nTokenStaked.payFeeToStakedNToken(vaultConfig.borrowCurrencyId, nTokenFee, blockTime);

        // Collateral required is equal to the interest portion of the borrow (fCash - underlyingAmount) and then
        // any additional collateral buffer required by configuration (this is a percentage of the underlying amount
        // borrowed.
        int256 underlyingAmount = assetRate.convertToUnderlying(assetCashAmount);
        
        // Calculate the user's leverage ratio here and ensure that it is less than what is allowed.
        int256 underlyingTotalCollateral = fCash.sub(underlyingAmount).add(collateralBuffer);
        require(
            fCash.divInRatePrecision(underlyingTotalCollateral).add(Constants.RATE_PRECISION) < vaultConfig.maximumLeverageRatio
        );

        // Convert the collateral required to asset cash
        assetCashCollateralRequired = assetRate.convertFromUnderlying(underlyingTotalCollateral).add(nTokenFee);
        // All of the collateral will be added to the vault
        assetCashToVault = assetCashToVault.add(assetCashCollateralRequired);

        vaultAccount.maturity = vaultState.currentMaturity;
        vaultAccount.fCashShare = SafeInt256.toInt(fCash).neg();
        vaultState.currentfCashBalance = vaultState.currentfCashBalance.sub(fCash);
    }

    function enterNextVault(
        VaultConfig memory vaultConfig,
        address vault,
        address account,
        uint256 fCash,
        uint256 maxBorrowRate,
        uint256 blockTime
    ) internal returns (
        int256 assetCashCollateralRequired,
        int256 assetCashToVault
    ) {
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
    function exitActiveVault(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        int256 fCash,
        uint256 maxLendRate,
        uint256 blockTime
    ) internal returns (
        int256 assetCashCostToExit
    ) {
        checkAndSettleVault(vaultConfig, vaultState, blockTime);
        // Netting off the fCash cannot go above zero (we don't want the account to over lend their position)
        require(fCash > 0 && vaultAccount.fCashShare.add(fCash) <= 0);
        {
            // You can only exit the current vault or the next vault term.
            uint256 nextTerm = vaultState.currentMaturity.add(vaultConfig.termLengthInDays.mul(Constants.DAY));
            require(
                vaultAccount.fCashMaturity == vaultState.currentMaturity ||
                vaultAccount.fCashMaturity == nextTerm
            );
        }

        (
            int256 assetCashCostToLend,
            AssetRateParameters memory assetRate
        ) = _executeTrade(
            vaultConfig.borrowCurrencyId,
            vaultAccount.fCashMaturity,,
            fCash, // positive amount of fCash to lend (checked above)
            maxLendRate,
            blockTime
        );

        // TODO: the account has a claim on the total vault cash balance in addition to any
        // cash balance in their account. This cash balance is here from on settlements
        int256 vaultCashBalanceClaim = vaultState.cashBalance.mul(vaultAccount.fCashShare).div(vaultState.currentfCashBalance);

        if (assetCashCostToLend == 0) {
            // If the cost to lend is zero it signifies that there was insufficient liquidity,
            // therefore we will just deposit the asset cash instead of lending. This will be
            // sufficient to cover the fCash debt, and in all likelihood the account will accrue
            // some amount assetCash interest over the amount they owe.
            assetCashCostToLend = assetRate.convertFromUnderlying(fCash).neg();
            // Net off from the cost to lend the amount the account has already deposited
            assetCashCostToExit = assetCashCostToLend.add(vaultAccount.cashBalance);
            // In this case we just mark that the account has deposited some amount of asset cash
            // against their fCash. Once maturity occurs we will mark a settlement rate and the
            // account can fully exit their position by netting off the fCash.
            vaultAccount.cashBalance = assetCashCostToLend;
        } else {
            int256 remainingfCash = vaultAccount.fCashShare.add(fCash);

            if (remainingfCash == 0) {
                // If fully exiting the fCash position then we can use all of the deposit and
                // clear the maturity
                assetCashCostToExit = assetCashCostToLend.add(vaultAccount.cashBalance);
                vaultAccount.fCashShare = 0;
                vaultAccount.fCashMaturity = 0;
                vaultAccount.cashBalance = 0;
            } else {
                // If partially exiting the fCash position then we can apply a prorata portion
                // of the deposit against the cost to exit.
                assetCashDepositShare = vaultAccount.cashBalance.mul(remainingfCash).div(vaultAccount.fCashShare);
                assetCashCostToExit = assetCashCostToLend.add(assetCashDepositShare);

                vaultAccount.assetCashDeposit = vaultAccount.assetCashDeposit.sub(assetCashDepositShare);
                vaultAccount.fCashShare = remainingfCash;
            }

            // Modify the vault state since were are changing the fCash balance here.
            vaultState.currentfCashBalance = vaultState.currentfCashBalance.add(fCash);
        }
        
        // If assetCashCostToExit < 0 then the account will deposit that amount of cash into
        // the vault, if the assetCashCostToExit > 0 then the account will withdraw their profits
        // from the vault.
        vaultState.cashBalance = vaultState.cashBalance.sub(assetCashCostToExit);
    }

    function exitMaturedVault(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount,
        uint256 blockTime
    ) internal returns (int256 assetCashCostToExit) {
        checkAndSettleVault(vaultConfig, vaultState, blockTime);
        require(vaultAccount.fCashMaturity <= blockTime);

        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            vaultAccount.fCashMaturity,
            blockTime
        );

        assetCashCostToExit = settlementRate.convertFromUnderlying(vaultAccount.fCashShare)
            .add(vaultAccount.assetCashDeposit);
        
        vaultAccount.fCashShare = 0;
        vaultAccount.assetCashDeposit = 0;
        vaultAccount.fCashMaturity = 0;

        // No need to update the vault config, it will have proceeded to the next term already
    }

    function exitVaultGlobal(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 vaultSharesSettled,
        uint256 vaultTotalSupply,
        uint256 blockTime
    ) internal returns (int256 assetCashCostToExit) {
        // TODO: what do we do if this has not settled properly?
        require(vaultState.currentMaturity < blockTime);
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateStateful(vaultConfig.borrowCurrencyId);

        // This is the net asset cash required to pay off the entire debt. If this value is positive
        // then the vault has made profits on the interest from cash deposits alone.
        int256 netAssetCashRemaining = assetRate.convertFromUnderlying(vaultState.currentfCashBalance)
            .add(vaultState.cashBalance);

        assetCashCostToExit = netAssetCashRemaining.mul(vaultSharesSettled).div(vaultTotalSupply);

        // Since we do not modify the fCash balance via lending, we don't update it here.
        vaultState.cashBalance = vaultState.cashBalance.sub(assetCashCostToExit);
    }

    function _executeTrade(
        uint16 currencyId,
        uint256 maturity
        int256 fCash,
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

        if (fCash < 0) {
            require(market.lastImpliedRate <= rateLimit);
        } else {
            require(market.lastImpliedRate >= rateLimit);
        }

        return (assetCash, cashGroup.assetRate);
    }
}