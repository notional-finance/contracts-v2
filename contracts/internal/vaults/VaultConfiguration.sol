// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../markets/AssetRate.sol";
import "../markets/DateTime.sol";
import "../balances/TokenHandler.sol";

library VaultConfiguration {
    using TokenHandler for Token;
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

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
        vaultConfig.minAccountBorrowSize = int256(s.minAccountBorrowSize).mul(Constants.INTERNAL_TOKEN_PRECISION);
        vaultConfig.termLengthInSeconds = uint256(s.termLengthInDays).mul(Constants.DAY);
        vaultConfig.maxNTokenFeeRate = int256(uint256(s.maxNTokenFeeRate5BPS).mul(Constants.BASIS_POINT * 5));
        vaultConfig.maxLeverageRatio = int256(uint256(s.maxLeverageRatioBPS).mul(Constants.BASIS_POINT));

        vaultConfig.riskFactor = s.riskFactor;
    }

    function setVaultConfig(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) internal {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        // Sanity check this value, leverage ratio must be greater than 1
        require(uint256(Constants.RATE_PRECISION) < uint256(vaultConfig.maxLeverageRatioBPS).mul(Constants.BASIS_POINT));

        store[vaultAddress] = vaultConfig;
    }

    function getVaultState(
        VaultConfig memory vaultConfig,
        uint256 maturity
    ) internal view returns (VaultState memory vaultState) {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][maturity];

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
        VaultStateStorage storage s = store[vaultConfig.vault][vaultState.maturity];

        require(type(int88).min <= vaultState.totalAssetCash && vaultState.totalAssetCash <= type(int88).max); // dev: asset cash overflow
        require(type(int88).min <= vaultState.totalfCash && vaultState.totalfCash <= type(int88).max); // dev: total fcash overflow

        s.totalAssetCash= int88(vaultState.totalAssetCash);
        s.totalfCash = int88(vaultState.totalfCash);
        s.isFullySettled = vaultState.isFullySettled;
    }

    /**
     * @notice Returns that status of a given flagID
     */
    function getFlag(
        VaultConfig memory vaultConfig,
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

    function getNextMaturity(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal pure returns (uint256) {
        // TODO: implement
    }

    function getNTokenFee(
        VaultConfig memory vaultConfig,
        int256 leverageRatio,
        int256 fCash
    ) internal pure returns (int256 nTokenFee) {
        // If there is no leverage then we don't charge a fee.
        if (leverageRatio <= Constants.RATE_PRECISION) return 0;

        // Linearly interpolate the fee between the maxLeverageRatio and the minimum leverage
        // ratio (Constants.RATE_PRECISION)
        // nTokenFee = (leverage - 1) * (maxFee / (maxLeverage - 1))

        // No overflow and positive, checked above.
        int256 leverageRatioAdj = leverageRatio - Constants.RATE_PRECISION;
        // All of these figures are in RATE_PRECISION
        int256 nTokenFeeRate = leverageRatioAdj
            .mul(vaultConfig.maxNTokenFeeRate)
            // maxLeverageRatio must be > 1 when set in governance, also vaults are
            // not allowed to exceed the maxLeverageRatio
            .div(vaultConfig.maxLeverageRatio - Constants.RATE_PRECISION);

        // nTokenFee is expected to be a positive number
        nTokenFee = fCash.neg().mulInRatePrecision(nTokenFeeRate);
    }

    function underlyingValueOf(
        VaultConfig memory vaultConfig,
        address account
    ) internal view returns (int256 valueOf) {
        // TODO: implement
    }

    function isInSettlement(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal view returns (bool) {
        // TODO: implement
    }


    /**
     * @notice Updates state when the vault is being settled.
     */
    function settleVault(
        VaultConfig memory vaultConfig,
        uint256 maturity,
        int256 assetCashRaised,
        uint256 blockTime
    ) internal returns (int256 netAssetCash) {
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

        setVaultState(vaultConfig, vaultState);


        // TODO: how do we determine if a vault is empty and must redeem?
    }

    /**
     * @notice Transfers asset cash between Notional and the vault. Vaults must always keep cash
     * balances in the asset cash token if they are not deployed into the strategy.
     * @param vaultConfig the vault config
     * @param netAssetTransferInternal If positive, then taking asset cash from the vault into Notional,
     * if negative then depositing cash from Notional into the vault
     * @param actualTransferExternal returns the actual amount transferred in external precision
     * @param actualTransferInternal returns the actual amount transferred in internal precision
     */
    function transferVault(
        VaultConfig memory vaultConfig,
        int256 netAssetTransferInternal
    ) internal returns (
        int256 actualTransferExternal,
        int256 actualTransferInternal
    ) {
        // If net asset transfer > 0 then we are taking asset cash from the vault into Notional
        // If net asset transfer < 0 then we are deposit cash into the vault
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        actualTransferExternal = assetToken.transfer(
            vaultConfig.vault, 
            vaultConfig.borrowCurrencyId,
            assetToken.convertToExternal(netAssetTransferInternal)
        );
        actualTransferInternal = assetToken.convertToInternal(actualTransferExternal);
    }

}