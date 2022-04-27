// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

library VaultConfiguration {
    uint16 internal constant ENABLED            = 1 << 0;
    uint16 internal constant ALLOW_REENTER      = 1 << 1;
    uint16 internal constant IS_INSURED         = 1 << 2;
    uint16 internal constant CAN_INITIALIZE     = 1 << 3;
    uint16 internal constant ACCEPTS_COLLATERAL = 1 << 4;

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
        address vaultAddress,
        uint256 maturity
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultAddress][maturity];

        vaultState.maturity = maturity;
        vaultState.totalAssetCash = s.totalAssetCash;
        vaultState.totalfCash = s.totalfCash;
        vaultState.isFullySettled = s.isFullySettled;
    }

    function setVaultState(
        address vaultAddress,
        VaultState memory vaultState
    ) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultAddress][vaultState.maturity];

        require(type(int88).min <= vaultState.totalAssetCash && vaultState.totalAssetCash <= type(int88).max); // dev: asset cash overflow
        require(type(int88).min <= vaultState.totalfCash && vaultState.totalfCash <= type(int88).max); // dev: total fcash overflow

        s.totalAssetCash= int88(vaultState.totalAssetCash);
        s.totalfCash = int88(vaultState.totalfCash);
        s.isFullySettled = vaultState.isFullySettled;
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
        // NOTE: termLengthInSeconds cannot be 0
        uint256 offset = blockTimeUTC0 % vaultConfig.termLengthInSeconds;

        return blockTimeUTC0.sub(offset).add(vaultConfig.termLengthInSeconds);
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

    function getNTokenFee() internal {}


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

}