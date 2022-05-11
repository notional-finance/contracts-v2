// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../markets/AssetRate.sol";
import "../markets/DateTime.sol";
import "../nToken/nTokenStaked.sol";
import "../balances/TokenHandler.sol";
import "../balances/BalanceHandler.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

library VaultConfiguration {
    using TokenHandler for Token;
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    event ProtocolInsolvency(uint16 currencyId, address vault, int256 shortfall);

    uint16 internal constant ENABLED            = 1 << 0;
    uint16 internal constant ALLOW_REENTER      = 1 << 1;
    uint16 internal constant IS_INSURED         = 1 << 2;

    function _getVaultConfig(
        address vaultAddress
    ) private view returns (VaultConfig memory vaultConfig) {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfigStorage storage s = store[vaultAddress];

        vaultConfig.flags = s.flags;
        vaultConfig.borrowCurrencyId = s.borrowCurrencyId;
        vaultConfig.maxVaultBorrowSize = s.maxVaultBorrowSize;
        vaultConfig.minAccountBorrowSize = int256(s.minAccountBorrowSize).mul(Constants.INTERNAL_TOKEN_PRECISION);
        vaultConfig.termLengthInSeconds = uint256(s.termLengthInDays).mul(Constants.DAY);
        vaultConfig.maxNTokenFeeRate = int256(uint256(s.maxNTokenFeeRate5BPS).mul(Constants.BASIS_POINT * 5));
        vaultConfig.maxLeverageRatio = int256(uint256(s.maxLeverageRatioBPS).mul(Constants.BASIS_POINT));
        vaultConfig.capacityMultiplierPercentage = int256(uint256(s.capacityMultiplierPercentage));
        vaultConfig.liquidationRate = int256(uint256(s.liquidationRate));
    }

    function getVaultConfigStateful(
        address vaultAddress
    ) internal returns (VaultConfig memory vaultConfig) {
        vaultConfig = _getVaultConfig(vaultAddress);
        vaultConfig.assetRate = AssetRate.buildAssetRateStateful(vaultConfig.borrowCurrencyId);
    }

    function getVaultConfigView(
        address vaultAddress
    ) internal returns (VaultConfig memory vaultConfig) {
        vaultConfig = _getVaultConfig(vaultAddress);
        vaultConfig.assetRate = AssetRate.buildAssetRateView(vaultConfig.borrowCurrencyId);
    }

    function setVaultEnabledStatus(
        address vaultAddress,
        bool enable
    ) internal {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfigStorage storage s = store[vaultAddress];
        uint16 flags = s.flags;

        if (enable) {
            s.flags = flags | VaultConfiguration.ENABLED;
        } else {
            s.flags = flags & ~VaultConfiguration.ENABLED;
        }
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
        vaultState.totalfCashRequiringSettlement = s.totalfCashRequiringSettlement;
        vaultState.totalfCash = s.totalfCash;
        vaultState.isFullySettled = s.isFullySettled;
        vaultState.accountsRequiringSettlement = s.accountsRequiringSettlement;
    }

    function setVaultState(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState
    ) internal {
        mapping(address => mapping(uint256 => VaultStateStorage)) storage store = LibStorage.getVaultState();
        VaultStateStorage storage s = store[vaultConfig.vault][vaultState.maturity];

        require(type(int88).min <= vaultState.totalfCash && vaultState.totalfCash <= 0); // dev: total fcash overflow
        // Total fCash requiring settlement is always less than total fCash
        require(vaultState.totalfCash <= vaultState.totalfCashRequiringSettlement 
            && vaultState.totalfCashRequiringSettlement <= 0); // dev: total fcash requiring settlement overflow
        require(vaultState.accountsRequiringSettlement <= type(uint32).max); // dev: accounts settlement overflow

        s.totalfCashRequiringSettlement= int88(vaultState.totalfCashRequiringSettlement);
        s.totalfCash = int88(vaultState.totalfCash);
        s.isFullySettled = vaultState.isFullySettled;
        s.accountsRequiringSettlement = uint32(vaultState.accountsRequiringSettlement);
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

    /**
     * @notice Returns the total amount of debt in a vault, will over estimate the actual amount of
     * debt if there are accounts with escrowed asset cash. The effect of this would mean that vaults
     * would be more conservative with their total borrow capacity and leverage ratios.
     */
    function getTotalVaultDebt(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal view returns (int256 totalVaultfCashDebt) {
        // NOTE: this is not completely correct because it does not take into account escrowed asset cash
        VaultState memory vaultState = getVaultState(vaultConfig, getCurrentMaturity(vaultConfig, blockTime));
        totalVaultfCashDebt = vaultState.totalfCash;
        
        if (getFlag(vaultConfig, VaultConfiguration.ALLOW_REENTER)) {
            // If this is true then there is potentially debt in the next term as well
            VaultState memory nextTerm = getVaultState(
                vaultConfig,
                vaultState.maturity.add(vaultConfig.termLengthInSeconds)
            );

            totalVaultfCashDebt = totalVaultfCashDebt.add(nextTerm.totalfCash);
        }
    }

    /**
     * @notice Checks the total borrow capacity for a vault across its active terms (the current term),
     * and the next term. Ensures that the total debt is less than the capacity defined by nToken insurance.
     */
    function checkTotalBorrowCapacity(
        VaultConfig memory vaultConfig,
        int256 stakedNTokenPV,
        uint256 blockTime
    ) internal view {
        int256 totalVaultfCashDebt = getTotalVaultDebt(vaultConfig, blockTime);

        int256 maxNTokenCapacity = stakedNTokenPV
            .mul(vaultConfig.capacityMultiplierPercentage)
            .div(Constants.PERCENTAGE_DECIMALS);

        require(totalVaultfCashDebt.neg() <= maxNTokenCapacity, "Insufficient capacity");
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
    }

    function settlePooledfCash(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        AssetRateParameters memory settlementRate
    ) internal {
        if (vaultState.totalfCashRequiringSettlement > 0) {
            // It's possible that there is no fCash requiring settlement if everyone has exited or
            // all accounts require specialized settlement but in most cases this will be true.
            int256 assetCashRequired = settlementRate.convertFromUnderlying(
                vaultState.totalfCashRequiringSettlement.neg()
            );
            (/* */, int256 actualTransferInternal) = transferVault(vaultConfig, assetCashRequired);
            require(actualTransferInternal == assetCashRequired); // dev: transfer amount mismatch

            vaultState.totalfCash = vaultState.totalfCash.sub(vaultState.totalfCashRequiringSettlement);
            vaultState.totalfCashRequiringSettlement = 0;
        }
    }

    function resolveCashShortfall(
        VaultConfig memory vaultConfig,
        int256 assetCashShortfall,
        uint256 nTokensToRedeem
    ) internal {
        uint16 currencyId = vaultConfig.borrowCurrencyId;
        // First attempt to redeem nTokens
        (/* int256 actualNTokensRedeemed */, int256 assetCashRaised) = nTokenStaked.redeemNTokenToCoverShortfall(
            currencyId,
            SafeInt256.toInt(nTokensToRedeem),
            assetCashShortfall,
            block.timestamp
        );

        int256 remainingShortfall = assetCashRaised.sub(assetCashShortfall);
        if (remainingShortfall > 0) {
            // Then reduce the reserves
            (int256 reserveInternal, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(Constants.RESERVE, currencyId);

            if (remainingShortfall <= reserveInternal) {
                BalanceHandler.setReserveCashBalance(currencyId, reserveInternal - remainingShortfall);
            } else {
                // At this point the protocol needs to raise funds from sNOTE
                BalanceHandler.setReserveCashBalance(currencyId, 0);
                // Disable the vault, users can still exit but no one can enter.
                setVaultEnabledStatus(vaultConfig.vault, false);
                emit ProtocolInsolvency(currencyId, vaultConfig.vault, remainingShortfall - reserveInternal);
            }
        }
    }
}