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
        VaultConfig memory vaultConfig,
        uint256 maturity
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vaultAddress][maturity];

        vaultState.maturity = maturity;
        vaultState.totalAssetCash = s.totalAssetCash;
        vaultState.totalfCash = s.totalfCash;
        vaultState.isFullySettled = s.isFullySettled;
    }

    function setVaultState(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState
    ) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vaultAddress][vaultState.maturity];

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
     * @notice Updates state when the vault is being settled.
     */
    function settleVault(
        VaultConfig memory vaultConfig,
        uint256 maturity,
        int256 assetCashRaised,
        uint256 blockTime
    ) internal returns (int256, bool) {
        VaultState memory vaultState = getVaultState(vaultConfig, maturity);
        AssetRateParameters memory assetRate;

        if (blockTime < maturity) {
            // Before maturity, we use the current asset exchange rate
            assetRate = AssetRate.buildAssetRateStateful(vaultConfig.borrowCurrencyId);
        } else {
            // After maturity, we use the settlement rate
            assetRate = AssetRate.buildSettlementRateStateful(
                vaultConfig.borrowCurrencyId,
                maturity,
                blockTime
            );
        }

        vaultState.totalAssetCash = vaultState.totalAssetCash.add(assetCashRaised);
        // If this is gte 0, then we have sufficient cash to repay the debt. Else, we still need some more cash.
        netAssetCash = vaultState.totalAssetCash.add(assetRate.convertFromUnderlying(vaultState.totalfCash));
        vaultState.isFullySettled = netAssetCash >= 0;

        vaultConfig.setVaultState(vaultState);


        // TODO: how do we determine if a vault is empty and must redeem?
    }

}