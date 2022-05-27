// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {DateTime} from "../markets/DateTime.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {Token, TokenType, TokenHandler, AaveHandler} from "../balances/TokenHandler.sol";
import {GenericToken} from "../balances/protocols/GenericToken.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";
import {StakedNTokenSupply, StakedNTokenSupplyLib} from "../nToken/staking/StakedNTokenSupply.sol";

import {VaultConfig, VaultConfigStorage} from "../../global/Types.sol";
import {VaultStateLib, VaultState, VaultStateStorage} from "./VaultState.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";
import {IStakedNTokenAction} from "../../../interfaces/notional/IStakedNTokenAction.sol";

library VaultConfiguration {
    using TokenHandler for Token;
    using VaultStateLib for VaultState;
    using StakedNTokenSupplyLib for StakedNTokenSupply;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    event ProtocolInsolvency(uint16 currencyId, address vault, int256 shortfall);

    uint16 internal constant ENABLED                 = 1 << 0;
    uint16 internal constant ALLOW_REENTER           = 1 << 1;
    uint16 internal constant IS_INSURED              = 1 << 2;
    uint16 internal constant ONLY_VAULT_ENTRY        = 1 << 3;
    uint16 internal constant ONLY_VAULT_EXIT         = 1 << 4;
    uint16 internal constant ONLY_VAULT_ROLL         = 1 << 5;
    uint16 internal constant ONLY_VAULT_DELEVERAGE   = 1 << 6;

    function _getVaultConfig(
        address vaultAddress
    ) private view returns (VaultConfig memory vaultConfig) {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfigStorage storage s = store[vaultAddress];

        vaultConfig.vault = vaultAddress;
        vaultConfig.flags = s.flags;
        vaultConfig.borrowCurrencyId = s.borrowCurrencyId;
        vaultConfig.maxVaultBorrowSize = s.maxVaultBorrowSize;
        vaultConfig.minAccountBorrowSize = int256(s.minAccountBorrowSize).mul(Constants.INTERNAL_TOKEN_PRECISION);
        vaultConfig.termLengthInSeconds = uint256(s.termLengthInDays).mul(Constants.DAY);
        vaultConfig.feeRate = int256(uint256(s.feeRate5BPS).mul(Constants.FIVE_BASIS_POINTS));
        vaultConfig.minCollateralRatio = int256(uint256(s.minCollateralRatioBPS).mul(Constants.BASIS_POINT));
        vaultConfig.capacityMultiplierPercentage = int256(uint256(s.capacityMultiplierPercentage));
        vaultConfig.liquidationRate = s.liquidationRate;
        vaultConfig.reserveFeeShare = int256(uint256(s.reserveFeeShare));
    }

    function getVaultConfigNoAssetRate(
        address vaultAddress
    ) internal view returns (VaultConfig memory vaultConfig) {
        vaultConfig = _getVaultConfig(vaultAddress);
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
        // Sanity check this value, collateral ratio must be greater than 1
        require(uint256(Constants.RATE_PRECISION) < uint256(vaultConfig.minCollateralRatioBPS).mul(Constants.BASIS_POINT));
        // Liquidation rate must be greater than or equal to 100
        require(Constants.PERCENTAGE_DECIMALS <= vaultConfig.liquidationRate);
        // Reserve fee share must be less than or equal to 100
        require(vaultConfig.reserveFeeShare <= Constants.PERCENTAGE_DECIMALS);

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
     * @notice Returns the fee denominated in asset internal precision. The fee based on time to maturity
     * and the amount of fCash. If an account is lending fCash they are repaying their debt and will get a fee
     * rebate. It should not be possible for an account to get a larger fee rebate then they initially paid since
     * they cannot lend more than they borrowed and the fee rate decreases as we get closer to maturity.
     * @param vaultConfig vault configuration
     * @param fCash the amount of fCash the account is lending or borrowing
     * @param timeToMaturity time until maturity of fCash
     * @return netSNTokenFee fee paid to the snToken
     * @return netReserveFee fee paid to the protocol reserve
     */
    function getVaultFees(
        VaultConfig memory vaultConfig,
        int256 fCash,
        uint256 timeToMaturity
    ) internal pure returns (int256 netSNTokenFee, int256 netReserveFee) {
        // The fee rate is annualized, we prorate it linearly based on the time to maturity here
        int256 proratedFeeRate = vaultConfig.feeRate
            .mul(SafeInt256.toInt(timeToMaturity))
            .div(int256(Constants.YEAR));

        // If fCash < 0 we are borrowing and the total fee is positive, if fCash > 0 then we are lending and the fee should
        // be a rebate back to the account.
        int256 netTotalFee = vaultConfig.assetRate.convertFromUnderlying(fCash.neg().mulInRatePrecision(proratedFeeRate));
        // Reserve fee share is restricted to less than 100
        netReserveFee = netTotalFee.mul(vaultConfig.reserveFeeShare).div(Constants.PERCENTAGE_DECIMALS);
        netSNTokenFee = netTotalFee.sub(netReserveFee);
    }

    function _netDebtOutstanding(
        AssetRateParameters memory assetRate,
        int256 totalfCash,
        int256 totalAssetCash
    ) private pure returns (int256) {
        // NOTE: it is possible that totalAssetCash > 0 and therefore this would
        // return a negative debt outstanding
        return totalfCash.add(assetRate.convertToUnderlying(totalAssetCash)).neg();
    }

    /**
     * @notice Checks the total borrow capacity for a vault across its active terms (the current term),
     * and the next term. Ensures that the total debt is less than the capacity defined by nToken insurance.
     * @param vaultConfig vault configuration
     * @param vaultState the current vault state to get the total fCash debt
     * @param stakedNTokenUnderlyingPV the amount of staked nToken present value
     * @param totalSNTokenSupply total supply of snTokens
     * @param blockTime current block time
     * @return totalUnderlyingCapacity total capacity between this quarter and next
     * @return nextMaturityPredictedCapacity total capacity in the next quarter
     * @return totalOutstandingDebt positively valued debt outstanding
     * @return nextMaturityDebt positively valued debt in the next maturity
     */
    function getBorrowCapacity(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 stakedNTokenUnderlyingPV,
        uint256 totalSNTokenSupply,
        uint256 blockTime
    ) internal view returns (
        int256 totalUnderlyingCapacity,
        // Inside this method, total outstanding debt is a positive integer
        int256 nextMaturityPredictedCapacity,
        int256 totalOutstandingDebt,
        int256 nextMaturityDebt
    ) {
        totalUnderlyingCapacity = stakedNTokenUnderlyingPV
            .mul(vaultConfig.capacityMultiplierPercentage)
            .div(Constants.PERCENTAGE_DECIMALS);

        // This is a partially calculated storage slot for the vault's state. The mapping is from maturity
        // to vault state for this vault.
        mapping(uint256 => VaultStateStorage) storage vaultStore = LibStorage.getVaultState()[vaultConfig.vault];

        uint256 currentMaturity = getCurrentMaturity(vaultConfig, blockTime);
        bool isInSettlement = IStrategyVault(vaultConfig.vault).isInSettlement();
        
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
            if (nextMaturity == vaultState.maturity) {
                nextMaturityDebt = vaultState.totalfCash.neg();
            } else {
                VaultStateStorage storage s = vaultStore[nextMaturity];
                nextMaturityDebt = int256(uint256(s.totalfCash));
            }

            totalOutstandingDebt = totalOutstandingDebt.add(nextMaturityDebt);
            nextMaturityPredictedCapacity = _getNextMaturityCapacity(
                vaultConfig,
                currentMaturity,
                stakedNTokenUnderlyingPV,
                totalSNTokenSupply

            );
        }
    }

    function _getNextMaturityCapacity(
        VaultConfig memory vaultConfig,
        uint256 currentMaturity,
        int256 stakedNTokenUnderlyingPV,
        uint256 totalSNTokenSupply
    ) private view returns (int256 nextMaturityPredictedCapacity) {
        uint256 unstakeSignal = StakedNTokenSupplyLib.getStakedNTokenUnstakeSignal(
            vaultConfig.borrowCurrencyId,
            currentMaturity
        );

        // Predicted next maturity capacity is based on assuming that everyone who has signalled unstaking
        // will unstake and taking a proportional share of the current present value.
        int256 predictedStakedNTokenPV = stakedNTokenUnderlyingPV
            .mul((totalSNTokenSupply.sub(unstakeSignal)).toInt())
            .div(totalSNTokenSupply.toInt());

        // We cannot use any staked nToken capacity that may unstake in the next unstaking period
        // to determine the borrow 
        nextMaturityPredictedCapacity = predictedStakedNTokenPV
            .mul(vaultConfig.capacityMultiplierPercentage)
            .div(Constants.PERCENTAGE_DECIMALS);
    }


    function checkTotalBorrowCapacity(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 blockTime
    ) internal {
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(vaultConfig.borrowCurrencyId);
        // We do a call back via the proxy to get the present value of the staked nToken. The reason is that this calculation
        // adds significant bytecode weight so this is the only way to get the contract to be deployable.
        uint256 valueInAssetCash = IStakedNTokenAction(address(this))
            .stakedNTokenPresentValueAssetInternal(vaultConfig.borrowCurrencyId);
        int256 stakedNTokenUnderlyingPV = vaultConfig.assetRate.convertToUnderlying(valueInAssetCash.toInt());
        
        (
            int256 totalUnderlyingCapacity,
            int256 nextMaturityPredictedCapacity,
            // Inside this method, total outstanding debt is a positive integer
            int256 totalOutstandingDebt,
            int256 nextMaturityDebt
        ) = getBorrowCapacity(vaultConfig, vaultState, stakedNTokenUnderlyingPV, stakedSupply.totalSupply, blockTime);

        require(
            totalOutstandingDebt <= totalUnderlyingCapacity &&
            totalOutstandingDebt <= vaultConfig.maxVaultBorrowSize &&
            nextMaturityDebt <= nextMaturityPredictedCapacity,
            "Insufficient capacity"
        );
    }

    /**
     * @notice Calculates the collateral ratio of an account: (debtOutstanding - valueOfAssets) / debtOutstanding
     * All values in this method are calculated using asset cash denomination. Higher collateral equates to
     * greater risk.
     * @param vaultConfig vault config
     * @return collateralRatio for an account
     */
    function calculateCollateralRatio(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 vaultShares,
        int256 fCash,
        int256 escrowedAssetCash
    ) internal view returns (int256 collateralRatio) {
        (int256 vaultShareValue, int256 assetCashHeld) = vaultState.getCashValueOfShare(vaultConfig, vaultShares);

        // We do not discount fCash to present value so that we do not introduce interest
        // rate risk in this calculation. The economic benefit of discounting will be very
        // minor relative to the added complexity of accounting for interest rate risk.

        // Escrowed asset cash and asset cash held in the vault are both held as payment against
        // borrowed fCash, so we net them off here.

        // debtOutstanding can either be positive or negative here, if it is positive then
        // there is more fCash left to repay, if it is negative than we have more than enough asset cash
        // to repay the debt.
        int256 debtOutstanding = escrowedAssetCash
            .add(assetCashHeld)
            .add(vaultConfig.assetRate.convertFromUnderlying(fCash))
            .neg();

        // netAssetValue includes the value held in strategyTokens (vaultShareValue - assetCashHeld) net
        // off against the outstanding debt. netAssetValue can be either positive or negative here. If it
        // is positive (normal condition) then the account has more value than debt, if it is negative then
        // the account is insolvent (it cannot repay its debt if we sold all of its strategy tokens).
        int256 netAssetValue = vaultShareValue
            .sub(assetCashHeld)
            .sub(debtOutstanding);

        // We calculate the collateral ratio (netAssetValue to debt ratio):
        //  if netAssetValue > 0 and debtOutstanding > 0: collateralRatio > 0, closer to zero means more risk, less than 1 is insolvent
        //  if netAssetValue < 0 and debtOutstanding > 0: collateralRatio < 1, the account is insolvent
        //  if netAssetValue > 0 and debtOutstanding < 0: collateralRatio < 0, there is no risk at all (no debt left)
        //  if netAssetValue < 0 and debtOutstanding < 0: collateralRatio > 0, there is no risk at all (no debt left)
        if (debtOutstanding <= 0)  {
            // When there is no debt outstanding then we use a maximal collateral ratio to represent "infinity"
            collateralRatio = type(int256).max;
        } else {
            // The closer this is to zero the more risk there is. Below zero and the account is insolvent
            collateralRatio = netAssetValue.divInRatePrecision(debtOutstanding);
        }
    }

    function checkCollateralRatio(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 vaultShares,
        int256 fCash,
        int256 escrowedAssetCash
    ) internal view {
        int256 collateralRatio = calculateCollateralRatio(vaultConfig, vaultState, vaultShares, fCash, escrowedAssetCash);
        require(vaultConfig.minCollateralRatio <= collateralRatio, "Insufficient Collateral");
    }

    /**
     * @notice This will transfer asset tokens to the strategy vault and mint strategy tokens back to Notional.
     * Vaults cannot pull tokens from Notional (they are never granted approval) for security reasons.
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
        address vault = vaultConfig.vault;
        IERC20 token = IERC20(assetToken.tokenAddress);

        // Do the transfer, ensuring that we get the most accurate accounting of the amount transferred to the vault
        uint256 balanceBefore = token.balanceOf(vault);
        GenericToken.safeTransferOut(address(token), vault, transferAmount);
        uint256 balanceAfter = token.balanceOf(vault);

        strategyTokensMinted = IStrategyVault(vault).depositFromNotional(balanceAfter.sub(balanceBefore), data);
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

    function resolveCashShortfall(
        VaultConfig memory vaultConfig,
        int256 assetCashShortfall,
        uint256 nTokensToRedeem
    ) internal {
        uint16 currencyId = vaultConfig.borrowCurrencyId;
        // First attempt to redeem nTokens
        (/* int256 actualNTokensRedeemed */, int256 assetCashRaised) = StakedNTokenSupplyLib.redeemNTokenToCoverShortfall(
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