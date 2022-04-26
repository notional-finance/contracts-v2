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


    struct VaultConfigStorage {
        // Vault Flags (positions 0 to 15 starting from right):
        // 0: enabled - true if vault is enabled
        // 1: allowReenter - true if vault allows reentering before term expiration
        // 2: isInsured - true if vault is covered by nToken insurance
        // TODO: not sure if these two are are necessary...
        // 3: canInitialize - true if vault can be initialized
        // 4: acceptsCollateral - true if vault can accept collateral
        uint16 flags;

        // Each vault only borrows in a single currency
        uint16 borrowCurrencyId;
        // Absolute maximum vault size (fCash overflows at int88)
        // NOTE: we can reduce this to uint48 to allow for a 281 trillion token vault (in whole 8 decimals)
        uint88 maxVaultBorrowSize;
        // Specified in whole tokens in 1e8 precision, allows a 4.2 billion min borrow size
        uint32 minAccountBorrowSize;
        // A value in XXX scale that represents the relative risk of this vault. Governs how large the
        // vault can get relative to staked nToken insurance (TODO: how much leverage should we allow?)
        uint32 riskFactor;
        // The number of days of each vault term (this is sufficient for 20 year vaults)
        uint16 termLengthInDays;
        // Allows up to a 12.75% fee
        uint8 nTokenFee5BPS;
        // Can be anywhere from 0% to 255% additional collateral required on the principal borrowed
        uint8 collateralBufferPercent;

        // 48 bytes left
    }

    struct VaultConfig {
        uint16 flags;
        uint16 borrowCurrencyId;
        int256 maxBorrowSize;
        uint256 riskFactor;
        uint256 termLength;
    }

    /// @notice Represents a Vault's current borrow and collateral state
    struct VaultStorage {
        // This represents cash held against fCash balances. If it is negative then
        // the vault is in shortfall.
        int88 cashBalance;
        // This represents the total amount of borrowing in the vault for the current
        // vault term.
        int88 currentfCashBalance;
        // TODO: if we removed this and made something int80 then we could fit all
        // three variables in a storage slot
        uint32 currentMaturity;

        // NOTE: This is split into a new storage slot
        // This holds the amount of fCash that is being borrowed in the next term
        // for accounts that are rolling their position forward.
        int88 nextTermfCashBalance;
    }

    /// @notice Represents an account's position within an individual vault
    struct VaultAccountStorage {
        // Share of the total fCash borrowed in the vault. If total fCash
        // is paid down on the vault, then the account will owe less as a result.
        int88 fCashShare;
        // This is the amount of asset cash deposited and held against the fCash
        // as collateral for the borrowing.
        int88 assetCashDeposit;
        // Represents the maturity at which the fCash is owed
        uint32 fCashMaturity; 

        // NOTE: 48 bytes left
    }

    function getVault(
        address vaultAddress
    ) internal view returns (VaultConfig memory vaultConfig) {
        // get vault config

    }

    function setVaultConfiguration(
        VaultConfig memory vaultConfig,
        address vaultAddress
    ) internal {
        // set vault config

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
            vaultAccount.fCashMaturity == 0 ||
            vaultAccount.fCashMaturity == vaultState.currentMaturity
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
        int256 collateralBuffer = underlyingAmount.mul(vaultConfig.collateralBufferPercent).div(Constants.PERCENT_DECIMALS);

        // Convert the collateral required to asset cash
        assetCashCollateralRequired = assetRate.convertFromUnderlying(fCash.sub(underlyingAmount).add(collateralBuffer));

        vaultAccount.assetCashDeposit = vaultAccount.assetCashDeposit.add(assetCashCollateralRequired);
        vaultAccount.fCashMaturity = vaultState.currentMaturity;
        // TODO: do we need to do any special math here?
        vaultAccount.fCashShare = SafeInt256.toInt(fCash).neg();
        vaultState.currentfCashBalance = vaultState.currentfCashBalance.sub(fCash);
        vaultState.cashBalance = vaultState.cashBalance.add(assetCashCollateralRequired);
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

        if (assetCashCostToLend == 0) {
            // If the cost to lend is zero it signifies that there was insufficient liquidity,
            // therefore we will just deposit the asset cash instead of lending. This will be
            // sufficient to cover the fCash debt, and in all likelihood the account will accrue
            // some amount assetCash interest over the amount they owe.
            assetCashCostToLend = assetRate.convertFromUnderlying(fCash).neg();
            // Net off from the cost to lend the amount the account has already deposited
            assetCashCostToExit = assetCashCostToLend.add(vaultAccount.assetCashDeposit);
            // In this case we just mark that the account has deposited some amount of asset cash
            // against their fCash. Once maturity occurs we will mark a settlement rate and the
            // account can fully exit their position by netting off the fCash.
            vaultAccount.assetCashDeposit = assetCashCostToLend;
        } else {
            int256 remainingfCash = vaultAccount.fCashShare.add(fCash);

            if (remainingfCash == 0) {
                // If fully exiting the fCash position then we can use all of the deposit and
                // clear the maturity
                assetCashCostToExit = assetCashCostToLend.add(vaultAccount.assetCashDeposit);
                vaultAccount.fCashShare = 0;
                vaultAccount.fCashMaturity = 0;
                vaultAccount.assetCashDeposit = 0;
            } else {
                // If partially exiting the fCash position then we can apply a prorata portion
                // of the deposit against the cost to exit.
                assetCashDepositShare = vaultAccount.assetCashDeposit.mul(remainingfCash).div(vaultAccount.fCashShare);
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

    function _excecuteTrade(
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