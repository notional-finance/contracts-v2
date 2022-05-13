// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {DateTime} from "../markets/DateTime.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {nTokenStaked} from "../nToken/nTokenStaked.sol";
import {Token, TokenType, TokenHandler, AaveHandler} from "../balances/TokenHandler.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";

import {VaultConfig, VaultConfigStorage} from "../../global/Types.sol";
import {VaultStateLib, VaultState, VaultStateStorage} from "./VaultState.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

library VaultConfiguration {
    using TokenHandler for Token;
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    event ProtocolInsolvency(uint16 currencyId, address vault, int256 shortfall);

    uint16 internal constant ENABLED                 = 1 << 0;
    uint16 internal constant ALLOW_REENTER           = 1 << 1;
    uint16 internal constant IS_INSURED              = 1 << 2;
    uint16 internal constant PREFER_ASSET_CASH       = 1 << 3;
    uint16 internal constant ONLY_VAULT_ENTRY        = 1 << 4;
    uint16 internal constant ONLY_VAULT_DELEVERAGE   = 1 << 5;

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
    ) internal view returns (VaultConfig memory vaultConfig) {
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

    /**
     * @notice Returns that status of a given flagID
     */
    function getFlag(VaultConfig memory vaultConfig, uint16 flagID) internal pure returns (bool) {
        return (vaultConfig.flags & flagID) == flagID;
    }

    /**
     * @notice Returns the current maturity based on the term length modulo the
     * current time.
     * @param vaultConfig vault configuration
     * @param blockTime current block time
     * @return the current maturity for the vault given the block time
     */
    function getCurrentMaturity(VaultConfig memory vaultConfig, uint256 blockTime) internal pure returns (uint256) {
        uint256 blockTimeUTC0 = DateTime.getTimeUTC0(blockTime);
        // NOTE: termLengthInSeconds cannot be 0
        uint256 offset = blockTimeUTC0 % vaultConfig.termLengthInSeconds;

        return blockTimeUTC0.sub(offset).add(vaultConfig.termLengthInSeconds);
    }

    /**
     * @notice Returns the nToken fee denominated in asset internal precision. The nTokenFee
     * is assessed based on the linear interpolation between the min and the max leverage and
     * then scaled based on the time to maturity.
     * @param vaultConfig vault configuration
     * @param leverageRatio the amount of leverage the account is taking
     * @param fCash the amount of fCash the account is borrowing
     * @param timeToMaturity time until maturity of fCash
     * @return nTokenFee the amount of asset cash in internal precision paid to the nToken
     */
    function getNTokenFee(
        VaultConfig memory vaultConfig,
        int256 leverageRatio,
        int256 fCash,
        uint256 timeToMaturity
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
            .mul(SafeInt256.toInt(timeToMaturity))
            .mul(vaultConfig.maxNTokenFeeRate)
            // maxLeverageRatio must be > 1 when set in governance, also vaults are
            // not allowed to exceed the maxLeverageRatio
            .div(vaultConfig.maxLeverageRatio - Constants.RATE_PRECISION)
            .div(int256(Constants.YEAR));

        // nTokenFee is expected to be a positive number
        nTokenFee = vaultConfig.assetRate.convertFromUnderlying(fCash.neg().mulInRatePrecision(nTokenFeeRate));
    }

    function _netDebtOutstanding(
        AssetRateParameters memory assetRate,
        int256 totalfCash,
        int256 totalAssetCash
    ) private pure returns (int256) {
        return totalfCash.add(assetRate.convertToUnderlying(totalAssetCash));
    }

    /**
     * @notice Checks the total borrow capacity for a vault across its active terms (the current term),
     * and the next term. Ensures that the total debt is less than the capacity defined by nToken insurance.
     * @param vaultConfig vault configuration
     * @param vaultState the current vault state to get the total fCash debt
     * @param stakedNTokenUnderlyingPV the amount of staked nToken present value
     */
    function checkTotalBorrowCapacity(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 stakedNTokenUnderlyingPV,
        uint256 blockTime
    ) internal view {
        // This is a partially calculated storage slot for the vault's state. The mapping is from maturity
        // to vault state for this vault.
        mapping(uint256 => VaultStateStorage) storage vaultStore = LibStorage.getVaultState()[vaultConfig.vault];

        int256 totalUnderlyingCapacity = stakedNTokenUnderlyingPV
            .mul(vaultConfig.capacityMultiplierPercentage)
            .div(Constants.PERCENTAGE_DECIMALS);

        uint256 currentMaturity = getCurrentMaturity(vaultConfig, blockTime);
        bool isInSettlement = IStrategyVault(vaultConfig.vault).isInSettlement();
        int256 totalOutstandingDebt;
        
        // First, handle the current vault state
        if (currentMaturity == vaultState.maturity) {
            totalOutstandingDebt = _netDebtOutstanding(
                vaultConfig.assetRate,
                vaultState.totalfCash, 
                // Only account for asset cash when we're in settlement
                isInSettlement ? SafeInt256.toInt(vaultState.totalAssetCash) : 0
            );
        } else {
            // Fetch the current vault state's relevant data and do the math
            VaultStateStorage storage s = vaultStore[currentMaturity];
            totalOutstandingDebt = _netDebtOutstanding(
                vaultConfig.assetRate,
                -int256(uint256(s.totalfCash)), 
                // Only account for asset cash when we're in settlement
                isInSettlement ? int256(uint256(s.totalAssetCash)) : 0
            );
        }

        // Next, handle the next vault state (if it allows re-enters)
        if (getFlag(vaultConfig, VaultConfiguration.ALLOW_REENTER)) {
            uint256 nextMaturity = currentMaturity.add(vaultConfig.termLengthInSeconds);
            // Use the absolute value (positive) here to save a couple negations
            int256 nextMaturityDebtAbs;

            if (nextMaturity == vaultState.maturity) {
                nextMaturityDebtAbs = vaultState.totalfCash.neg();
            } else {
                VaultStateStorage storage s = vaultStore[currentMaturity];
                nextMaturityDebtAbs = int256(uint256(s.totalfCash));
            }

            // We cannot use any staked nToken capacity that may unstake in the next unstaking period
            // to determine the borrow 
            /*
            TODO: pass this value in
            int256 nextMaturityPredictedCapacity = predictedStakedNTokenPV
                .mul(vaultConfig.capacityMultiplierPercentage)
                .div(Constants.PERCENTAGE_DECIMALS);
            require(nextMaturityDebtAbs <= nextMaturityPredictedCapacity, "Insufficient capacity");
            */

            totalOutstandingDebt = totalOutstandingDebt.sub(nextMaturityDebtAbs);
        }

        require(totalOutstandingDebt.neg() <= totalUnderlyingCapacity, "Insufficient capacity");
    }

    /**
     * @notice This will allow the strategy vault to pull the approved amount of tokens from Notional. We allow
     * the strategy vault to pull tokens so that it can get an accurate accounting of the tokens it received in
     * case of tokens with transfer fees or other non-standard behaviors on transfer.
     * @param vaultConfig vault config
     * @param cashToTransferInternal amount to transfer in internal precision
     * @param data arbitrary data to pass to the vault
     * @return strategyTokensMinted the amount of strategy tokens minted and transferred back to the
     * Notional contract for escrow, will be credited back to the vault account.
     */
    function deposit(
        VaultConfig memory vaultConfig,
        int256 cashToTransferInternal,
        bytes calldata data
    ) internal returns (uint256 strategyTokensMinted) {
        if (cashToTransferInternal == 0) return 0;

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        int256 transferAmountExternal = assetToken.convertToExternal(cashToTransferInternal);

        if (assetToken.tokenType == TokenType.aToken) {
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
            // aTokens need to be converted when we handle the transfer since the external balance format
            // is not the same as the internal balance format that we use
            transferAmountExternal = AaveHandler.convertFromScaledBalanceExternal(
                underlyingToken.tokenAddress,
                transferAmountExternal
            );
        }
        
        // Ensures that transfer amounts are always positive
        uint256 transferAmount = SafeInt256.toUint(transferAmountExternal);
        IERC20(assetToken.tokenAddress).approve(vaultConfig.vault, transferAmount);
        strategyTokensMinted = IStrategyVault(vaultConfig.vault).depositFromNotional(transferAmount, data);
        IERC20(assetToken.tokenAddress).approve(vaultConfig.vault, 0);
    }

    /**
     * @notice This will call the strategy vault and have it redeem the specified amount of Notional strategy tokens
     * for asset tokens. The vault will transfer tokens to Notional.
     * @param vaultConfig vault config
     * @param strategyTokens amount of strategy tokens to redeem
     * @param data arbitrary data to pass to the vault
     * @return assetCashInternalRaised the amount of asset cash (positive) that was raised as a result of redeeming
     * strategy tokens
     */
    function redeem(
        VaultConfig memory vaultConfig,
        uint256 strategyTokens,
        bytes calldata data
    ) internal returns (int256 assetCashInternalRaised) {
        if (strategyTokens == 0) return 0;

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);

        uint256 balanceBefore = IERC20(assetToken.tokenAddress).balanceOf(address(this));
        // Tells the vault will redeem the strategy token amount and transfer asset tokens back to Notional
        IStrategyVault(vaultConfig.vault).redeemFromNotional(strategyTokens, data);
        uint256 balanceAfter = IERC20(assetToken.tokenAddress).balanceOf(address(this));

        // Subtraction is done inside uint256 so a negative amount will revert.
        int256 assetCashExternal = SafeInt256.toInt(balanceAfter.sub(balanceBefore));
        if (assetToken.tokenType == TokenType.aToken) {
            // Special handling for aave aTokens which are rebasing
            assetCashExternal = AaveHandler.convertToScaledBalanceExternal(
                vaultConfig.borrowCurrencyId,
                assetCashExternal
            );
        }

        assetCashInternalRaised = assetToken.convertToInternal(assetCashExternal);
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