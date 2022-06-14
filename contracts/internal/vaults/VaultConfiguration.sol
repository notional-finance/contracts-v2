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

import {
    VaultConfig,
    VaultAccount,
    VaultConfigStorage,
    VaultBorrowCapacityStorage,
    VaultSecondaryBorrowStorage
} from "../../global/Types.sol";
import {VaultStateLib, VaultState, VaultStateStorage} from "./VaultState.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

library VaultConfiguration {
    using TokenHandler for Token;
    using VaultStateLib for VaultState;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    /// @notice Emitted when a vault is unable to repay its debt
    event ProtocolInsolvency(uint16 currencyId, address vault, int256 shortfall);

    uint16 internal constant ENABLED                         = 1 << 0;
    uint16 internal constant ALLOW_ROLL_POSITION             = 1 << 1;
    // These flags switch the authentication on the vault methods such that all
    // calls must come from the vault itself.
    uint16 internal constant ONLY_VAULT_ENTRY                = 1 << 2;
    uint16 internal constant ONLY_VAULT_EXIT                 = 1 << 3;
    uint16 internal constant ONLY_VAULT_ROLL                 = 1 << 4;
    uint16 internal constant ONLY_VAULT_DELEVERAGE           = 1 << 5;
    uint16 internal constant ONLY_VAULT_SETTLE               = 1 << 6;
    // Some tokens may not be able to be redeemed until certain unlock times,
    // when this is flag is set vaultShares will be transferred to the liquidator instead
    // of redeemed
    uint16 internal constant TRANSFER_SHARES_ON_DELEVERAGE   = 1 << 7;
    // External vault methods will have re-entrancy protection on by default, however, some
    // vaults may need to call back into Notional so we can whitelist them for re-entrancy.
    uint16 internal constant ALLOW_REENTRANCY                = 1 << 8;

    function _getVaultConfig(
        address vaultAddress
    ) private view returns (VaultConfig memory vaultConfig) {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfigStorage storage s = store[vaultAddress];

        vaultConfig.vault = vaultAddress;
        vaultConfig.flags = s.flags;
        vaultConfig.borrowCurrencyId = s.borrowCurrencyId;
        vaultConfig.minAccountBorrowSize = int256(s.minAccountBorrowSize).mul(Constants.INTERNAL_TOKEN_PRECISION);
        vaultConfig.feeRate = int256(uint256(s.feeRate5BPS).mul(Constants.FIVE_BASIS_POINTS));
        vaultConfig.minCollateralRatio = int256(uint256(s.minCollateralRatioBPS).mul(Constants.BASIS_POINT));
        vaultConfig.maxDeleverageCollateralRatio = int256(uint256(s.maxDeleverageCollateralRatioBPS).mul(Constants.BASIS_POINT));
        // This is used in 1e9 precision on the stack (no overflow possible)
        vaultConfig.liquidationRate = (int256(uint256(s.liquidationRate)) * Constants.RATE_PRECISION) / Constants.PERCENTAGE_DECIMALS;
        vaultConfig.reserveFeeShare = int256(uint256(s.reserveFeeShare));
        vaultConfig.maxBorrowMarketIndex = s.maxBorrowMarketIndex;
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

    function setVaultEnabledStatus(address vaultAddress, bool enable) internal {
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
        // Liquidation rate must be greater than or equal to 100
        require(Constants.PERCENTAGE_DECIMALS <= vaultConfig.liquidationRate);
        // Reserve fee share must be less than or equal to 100
        require(vaultConfig.reserveFeeShare <= Constants.PERCENTAGE_DECIMALS);
        require(vaultConfig.maxBorrowMarketIndex != 0);
        // This must be true or else when deleveraging we could put an account further towards insolvency
        require(vaultConfig.minCollateralRatioBPS < vaultConfig.maxDeleverageCollateralRatioBPS);

        store[vaultAddress] = vaultConfig;
    }

    function setMaxBorrowCapacity(
        address vault,
        uint16 currencyId,
        uint80 maxBorrowCapacity
    ) internal {
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];
        cap.maxBorrowCapacity = maxBorrowCapacity;
    }

    function authorizeCaller(
        VaultConfig memory vaultConfig,
        address account,
        uint16 onlyVaultFlag
    ) internal view {
        if (getFlag(vaultConfig, onlyVaultFlag)) {
            // If the only vault method is flagged, then the sender must be the vault
            require(msg.sender == vaultConfig.vault, "Unauthorized");
        } else {
            // The base case is that the account must be the msg.sender
            require(account == msg.sender, "Unauthorized");
        }
    }

    /**
     * @notice Returns that status of a given flagID
     */
    function getFlag(VaultConfig memory vaultConfig, uint16 flagID) internal pure returns (bool) {
        return (vaultConfig.flags & flagID) == flagID;
    }

    /**
     * @notice Assess fees to the vault account. The fee based on time to maturity and the amount of fCash.
     * @param vaultConfig vault configuration
     * @param fCash the amount of fCash the account is lending or borrowing
     * @param timeToMaturity time until maturity of fCash
     */
    function assessVaultFees(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        int256 fCash,
        uint256 timeToMaturity
    ) internal {
        require(fCash <= 0);

        // The fee rate is annualized, we prorate it linearly based on the time to maturity here
        int256 proratedFeeRate = vaultConfig.feeRate
            .mul(SafeInt256.toInt(timeToMaturity))
            .div(int256(Constants.YEAR));

        // If fCash < 0 we are borrowing and the total fee is positive, if fCash > 0 then we are lending and the fee should
        // be a rebate back to the account.
        int256 netTotalFee = vaultConfig.assetRate.convertFromUnderlying(fCash.neg().mulInRatePrecision(proratedFeeRate));

        // Reserve fee share is restricted to less than 100
        int256 netReserveFee = netTotalFee.mul(vaultConfig.reserveFeeShare).div(Constants.PERCENTAGE_DECIMALS);
        int256 netNTokenFee = netTotalFee.sub(netReserveFee);

        BalanceHandler.incrementFeeToReserve(vaultConfig.borrowCurrencyId, netReserveFee);
        BalanceHandler.incrementVaultFeeToNToken(vaultConfig.borrowCurrencyId, netNTokenFee);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.sub(netTotalFee);
    }

    /**
     * @notice Updates the total borrow capacity for a vault and a currency. Reverts if borrowing goes above
     * the maximum allowed, always allows the total used to decrease. Called when borrowing, lending and settling
     * a vault. Tracks all fCash usage across all maturities as a single number even though they are not strictly
     * fungible with each other, this is just used as a heuristic for the total vault risk exposure.
     * @param vault address of vault
     * @param currencyId relevant currency id, all vaults will borrow in a primary currency, some vaults also borrow
     * in secondary or perhaps even tertiary currencies.
     * @param netfCash the net amount of fCash change (borrowing < 0, lending > 0)
     * @return totalUsedBorrowCapacity positively valued debt outstanding
     */
    function updateUsedBorrowCapacity(
        address vault,
        uint16 currencyId,
        int256 netfCash
    ) internal returns (int256 totalUsedBorrowCapacity) {
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];

        // Update the total used borrow capacity, when borrowing this number will increase (netfCash < 0),
        // when lending this number will decrease (netfCash > 0)
        totalUsedBorrowCapacity = int256(uint256(cap.totalUsedBorrowCapacity)).sub(netfCash);
        if (netfCash < 0) {
            // Always allow lending to reduce the total used borrow capacity to satisfy the case when the max borrow
            // capacity has been reduced by governance below the totalUsedBorrowCapacity. When borrowing, it cannot
            // go past the limit.
            require(totalUsedBorrowCapacity <= int256(uint256(cap.maxBorrowCapacity)), "Max Capacity");
        }

        // Total used borrow capacity can never go negative, this would suggest that we've lent past repayment
        // of the total fCash borrowed.
        cap.totalUsedBorrowCapacity = totalUsedBorrowCapacity.toUint().toUint80();
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
        int256 fCash
    ) internal view returns (int256 collateralRatio, int256 vaultShareValue) {
        vaultShareValue = vaultState.getCashValueOfShare(vaultConfig, vaultShares);

        // We do not discount fCash to present value so that we do not introduce interest
        // rate risk in this calculation. The economic benefit of discounting will be very
        // minor relative to the added complexity of accounting for interest rate risk.

        // Convert this to a positive number amount of asset cash
        int256 debtOutstanding = vaultConfig.assetRate.convertFromUnderlying(fCash.neg());

        // netAssetValue includes the value held in vaultShares (strategyTokenValue + assetCashHeld) net
        // off against the outstanding debt. netAssetValue can be either positive or negative here. If it
        // is positive (normal condition) then the account has more value than debt, if it is negative then
        // the account is insolvent (it cannot repay its debt if we sold all of its strategy tokens).
        int256 netAssetValue = vaultShareValue.sub(debtOutstanding);

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
        int256 fCash
    ) internal view {
        (int256 collateralRatio, /* */) = calculateCollateralRatio(vaultConfig, vaultState, vaultShares, fCash);
        require(vaultConfig.minCollateralRatio <= collateralRatio, "Insufficient Collateral");
    }

    /**
     * @notice This will transfer asset tokens to the strategy vault and mint strategy tokens back to Notional.
     * Vaults cannot pull tokens from Notional (they are never granted approval) for security reasons.
     * @param vaultConfig vault config
     * @param cashToTransferInternal amount to transfer in internal precision
     * @param maturity the maturity of the vault shares
     * @param data arbitrary data to pass to the vault
     * @return strategyTokensMinted the amount of strategy tokens minted
     */
    function deposit(
        VaultConfig memory vaultConfig,
        address account,
        int256 cashToTransferInternal,
        uint256 maturity,
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

        strategyTokensMinted = IStrategyVault(vault).depositFromNotional(
            account, balanceAfter.sub(balanceBefore), maturity, data
        );
    }

    /**
     * @notice This will call the strategy vault and have it redeem the specified amount of Notional strategy tokens
     * for asset tokens. The vault will transfer tokens to Notional.
     * @param vaultConfig vault config
     * @param strategyTokens amount of strategy tokens to redeem
     * @param maturity the maturity of the vault shares
     * @param data arbitrary data to pass to the vault
     * @return assetCashInternalRaised the amount of asset cash (positive) that was raised as a result of redeeming
     * strategy tokens
     */
    function redeem(
        VaultConfig memory vaultConfig,
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal returns (int256 assetCashInternalRaised) {
        if (strategyTokens == 0) return 0;

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);

        uint256 balanceBefore = IERC20(assetToken.tokenAddress).balanceOf(address(this));
        // Tells the vault will redeem the strategy token amount and transfer asset tokens back to Notional
        IStrategyVault(vaultConfig.vault).redeemFromNotional(account, strategyTokens, maturity, data);
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

}