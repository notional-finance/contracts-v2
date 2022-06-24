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
import {Token, TokenType, TokenHandler} from "../balances/TokenHandler.sol";
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

/// @notice Vault configuration holds per vault parameters and methods that interact
/// with vault level parameters (such as fee assessments, collateral ratios, capacity
/// limits, etc.)
library VaultConfiguration {
    using TokenHandler for Token;
    using VaultStateLib for VaultState;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address indexed vault, bool enabled);
    /// @notice Emitted when a vault has a shortfall upon settlement
    event VaultShortfall(uint16 indexed currencyId, address indexed vault, int256 shortfall);
    /// @notice Emitted when a vault has an insolvency that cannot be covered by the
    /// cash reserve
    event ProtocolInsolvency(uint16 indexed currencyId, address indexed vault, int256 shortfall);

    uint16 internal constant ENABLED                         = 1 << 0;
    uint16 internal constant ALLOW_ROLL_POSITION             = 1 << 1;
    // These flags switch the authentication on the vault methods such that all
    // calls must come from the vault itself.
    uint16 internal constant ONLY_VAULT_ENTRY                = 1 << 2;
    uint16 internal constant ONLY_VAULT_EXIT                 = 1 << 3;
    uint16 internal constant ONLY_VAULT_ROLL                 = 1 << 4;
    uint16 internal constant ONLY_VAULT_DELEVERAGE           = 1 << 5;
    uint16 internal constant ONLY_VAULT_SETTLE               = 1 << 6;
    // External vault methods will have re-entrancy protection on by default, however, some
    // vaults may need to call back into Notional so we can whitelist them for re-entrancy.
    uint16 internal constant ALLOW_REENTRANCY                = 1 << 7;

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
        vaultConfig.secondaryBorrowCurrencies = s.secondaryBorrowCurrencies;
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
        // The borrow currency cannot be duplicated as a secondary borrow currency
        require(vaultConfig.borrowCurrencyId != vaultConfig.secondaryBorrowCurrencies[0]);
        require(vaultConfig.borrowCurrencyId != vaultConfig.secondaryBorrowCurrencies[1]);
        require(vaultConfig.borrowCurrencyId != vaultConfig.secondaryBorrowCurrencies[2]);

        // Tokens with transfer fees create lots of issues with vault mechanics, we prevent them
        // from being listed here.
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
        require(!assetToken.hasTransferFee && !underlyingToken.hasTransferFee); 

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

    /// @notice Authorizes callers based on the vault flags set in the confiuration
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

    /// @notice Returns that status of a given flagID
    function getFlag(VaultConfig memory vaultConfig, uint16 flagID) internal pure returns (bool) {
        return (vaultConfig.flags & flagID) == flagID;
    }

    /// @notice Assess fees to the vault account. The fee based on time to maturity and the amount of fCash. Fees
    /// will be accrued to the nToken cash balance and the protocol cash reserve.
    /// @param vaultConfig vault configuration
    /// @param vaultAccount modifies the vault account temp cash balance in memory
    /// @param fCash the amount of fCash the account is lending or borrowing
    /// @param timeToMaturity time until maturity of fCash
    function assessVaultFees(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        int256 fCash,
        uint256 timeToMaturity
    ) internal {
        require(fCash <= 0);

        // The fee rate is annualized, we prorate it linearly based on the time to maturity here
        int256 proratedFeeRate = vaultConfig.feeRate
            .mul(timeToMaturity.toInt())
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

    /// @notice Updates the total borrow capacity for a vault and a currency. Reverts if borrowing goes above
    /// the maximum allowed, always allows the total used to decrease. Called when borrowing, lending and settling
    /// a vault. Tracks all fCash usage across all maturities as a single number even though they are not strictly
    /// fungible with each other, this is just used as a heuristic for the total vault risk exposure.
    /// @param vault address of vault
    /// @param currencyId relevant currency id, all vaults will borrow in a primary currency, some vaults also borrow
    /// in secondary or perhaps even tertiary currencies.
    /// @param netfCash the net amount of fCash change (borrowing < 0, lending > 0)
    /// @return totalUsedBorrowCapacity is the positively valued debt outstanding
    function updateUsedBorrowCapacity(
        address vault,
        uint16 currencyId,
        int256 netfCash
    ) internal returns (int256 totalUsedBorrowCapacity) {
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];

        // Update the total used borrow capacity, when borrowing this number will increase (netfCash < 0),
        // when lending this number will decrease (netfCash > 0). 
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

    /// @notice Updates the secondary borrow capacity for a vault, also tracks the per maturity fCash borrowed
    /// for the vault. We validate that the secondary fCashBorrowed is zeroed out when the vault is settled.
    /// @param vault address of vault
    /// @param currencyId relevant currency id
    /// @param maturity the maturity of the fCash
    /// @param netfCash the net amount of fCash change (borrowing < 0, lending > 0)
    function updateSecondaryBorrowCapacity(
        address vault,
        uint16 currencyId,
        uint256 maturity,
        int256 netfCash
    ) internal {
        // This will revert if we overflow the maximum borrow capacity
        updateUsedBorrowCapacity(vault, currencyId, netfCash);
        // Updates storage for the specific maturity so we can track this on chain.
        VaultSecondaryBorrowStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vault][maturity][currencyId];
        // This will revert if lending past the total amount borrowed
        balance.fCashBorrowed = int256(uint256(balance.fCashBorrowed)).sub(netfCash).toUint().toUint80();
    }

    /// @notice Calculates the collateral ratio of an account: (valueOfAssets - debtOutstanding) / debtOutstanding
    /// All values in this method are calculated using asset cash denomination. Lower collateral ratio equates to
    /// greater risk.
    /// @param vaultConfig vault config
    /// @param vaultState vault state, used to get the value of vault shares
    /// @param account address of the account holding the vault shares, sometimes the value of strategy tokens varies
    /// based on the holder (notably in the case of secondary borrows)
    /// @param vaultShares vault shares held by the account
    /// @param fCash debt held by the account
    /// @return collateralRatio for an account, expressed in 1e9 "RATE_PRECISION"
    /// @return vaultShareValue value of vault shares denominated in asset cash
    function calculateCollateralRatio(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        address account,
        uint256 vaultShares,
        int256 fCash
    ) internal view returns (int256 collateralRatio, int256 vaultShareValue) {
        vaultShareValue = vaultState.getCashValueOfShare(vaultConfig, account, vaultShares);

        // We do not discount fCash to present value so that we do not introduce interest
        // rate risk in this calculation. The economic benefit of discounting will be very
        // minor relative to the added complexity of accounting for interest rate risk.

        // Convert fCash to a positive amount of asset cash
        int256 debtOutstanding = vaultConfig.assetRate.convertFromUnderlying(fCash.neg());

        // netAssetValue includes the value held in vaultShares (strategyTokenValue + assetCashHeld) net
        // off against the outstanding debt. netAssetValue can be either positive or negative here. If it
        // is positive (normal condition) then the account has more value than debt, if it is negative then
        // the account is insolvent (it cannot repay its debt if we sold all of its strategy tokens).
        int256 netAssetValue = vaultShareValue.sub(debtOutstanding);

        // We calculate the collateral ratio (netAssetValue to debt ratio):
        //  if netAssetValue > 0 and debtOutstanding > 0: collateralRatio > 0, closer to zero means more risk
        //  if netAssetValue < 0 and debtOutstanding > 0: collateralRatio < 0, the account is insolvent
        //  if debtOutstanding == 0: collateralRatio is infinity, there is no risk at all (no debt left)
        if (debtOutstanding == 0)  {
            // When there is no debt outstanding then we use a maximal collateral ratio to represent "infinity"
            collateralRatio = type(int256).max;
        } else {
            collateralRatio = netAssetValue.divInRatePrecision(debtOutstanding);
        }
    }

    /// @notice Convenience method for checking that a collateral ratio remains above the configured minimum
    function checkCollateralRatio(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        VaultAccount memory vaultAccount
    ) internal view {
        (int256 collateralRatio, /* */) = calculateCollateralRatio(
            vaultConfig, vaultState, vaultAccount.account, vaultAccount.vaultShares, vaultAccount.fCash
        );
        require(vaultConfig.minCollateralRatio <= collateralRatio, "Insufficient Collateral");
    }

    /// @notice Transfers underlying tokens directly from the account into the vault, used in enterVault
    /// to deposit collateral from the account into the vault directly to skip additional ERC20 transfers.
    /// @param vaultConfig the vault configuration
    /// @param transferFrom the address to transfer from
    /// @param depositAmountExternal the amount to transfer from the account to the vault
    /// @return the amount of underlying external transferred to the vault
    function transferUnderlyingToVaultDirect(
        VaultConfig memory vaultConfig,
        address transferFrom,
        uint256 depositAmountExternal
    ) internal returns (uint256) {
        if (depositAmountExternal == 0) return 0;

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        Token memory underlyingToken = assetToken.tokenType == TokenType.NonMintable ? 
            assetToken :
            TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);

        address vault = vaultConfig.vault;
        if (underlyingToken.tokenType == TokenType.Ether) {
            require(msg.value == depositAmountExternal, "Invalid ETH");
            // Forward all the ETH to the vault
            GenericToken.transferNativeTokenOut(vault, msg.value);

            return msg.value;
        } else if (underlyingToken.hasTransferFee) {
            // In this case need to check the balance of the vault before and after
            uint256 balanceBefore = underlyingToken.balanceOf(vault);
            GenericToken.safeTransferFrom(underlyingToken.tokenAddress, transferFrom, vault, depositAmountExternal);
            uint256 balanceAfter = underlyingToken.balanceOf(vault);

            return balanceAfter.sub(balanceBefore);
        } else {
            GenericToken.safeTransferFrom(underlyingToken.tokenAddress, transferFrom, vault, depositAmountExternal);
            return depositAmountExternal;
        }
    }

    /// @notice This will transfer borrowed asset tokens to the strategy vault and mint strategy tokens
    /// in the vault account.
    /// @param vaultConfig vault config
    /// @param account account to pass to the vault
    /// @param cashToTransferInternal amount of asset cash to  transfer in internal precision
    /// @param maturity the maturity of the vault shares
    /// @param additionalUnderlyingExternal amount of additional underlying tokens already transferred to
    /// the vault in enterVault
    /// @param data arbitrary data to pass to the vault
    /// @return strategyTokensMinted the amount of strategy tokens minted
    function deposit(
        VaultConfig memory vaultConfig,
        address account,
        int256 cashToTransferInternal,
        uint256 maturity,
        uint256 additionalUnderlyingExternal,
        bytes calldata data
    ) internal returns (uint256 strategyTokensMinted) {
        uint256 underlyingTokensTransferred = transferFromNotional(
            vaultConfig.vault, vaultConfig.borrowCurrencyId, cashToTransferInternal
        );
        strategyTokensMinted = IStrategyVault(vaultConfig.vault).depositFromNotional(
            account, underlyingTokensTransferred.add(additionalUnderlyingExternal), maturity, data
        );
    }

    /// @notice Redeems and transfers asset cash to the vault from Notional
    /// @param receiver address that receives the token
    /// @param currencyId currency id to transfer
    /// @param cashToTransferInternal amount of asset cash to  transfer in internal precision
    /// @return underlyingTokensTransferred amount of underlying tokens transferred
    function transferFromNotional(
        address receiver,
        uint16 currencyId,
        int256 cashToTransferInternal
    ) internal returns (uint256 underlyingTokensTransferred) {
        if (cashToTransferInternal == 0) return 0;
        require(cashToTransferInternal > 0);

        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        int256 transferAmountExternal = assetToken.convertToExternal(cashToTransferInternal);

        // Both redeem an transfer return negative values to signify that assets have left the
        // the protocol. Flip it to a positive integer.
        if (assetToken.tokenType == TokenType.NonMintable) {
            // In the case of non-mintable tokens we transfer the asset token instead.
            underlyingTokensTransferred = assetToken.transfer(
                receiver, currencyId, transferAmountExternal.neg()
            ).neg().toUint();
        } else {
            // aToken balances are properly handled within redeem
            underlyingTokensTransferred = assetToken.redeem(
                currencyId, receiver, transferAmountExternal.toUint()
            ).neg().toUint();
        }
    }

    /// @notice Redeems without any debt repayment and sends tokens back to the account
    function redeemWithoutDebtRepayment(
        VaultConfig memory vaultConfig,
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal returns (int256 assetCashInternalRaised) {
        /// NOTE: assetInternalToRepayDebt is set to zero here
        return _redeem(
            vaultConfig, 
            RedeemParams(account, account, strategyTokens, maturity, 0),
            data
        );
    }

    /// @notice Redeems without any debt repayment and sends profits back to the receiver
    function redeemWithDebtRepayment(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        address receiver,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal {
        require(vaultAccount.tempCashBalance <= 0);
        // This method will revert if the tempCashBalance is not repaid, although the return value will be greater
        // than tempCashBalance due to rounding adjustments. Just clear tempCashBalance to remove the dust from
        // internal accounting (the dust will accrue to the protocol).
        _redeem(
            vaultConfig,
            RedeemParams(vaultAccount.account, receiver, strategyTokens, maturity, vaultAccount.tempCashBalance),
            data
        );
        vaultAccount.tempCashBalance = 0;
    }

    // @param account address of the account to pass to the vault
    // @param strategyTokens amount of strategy tokens to redeem
    // @param maturity the maturity of the vault shares
    // @param assetInternalToRepayDebt amount of asset cash in internal denomination required to repay debts
    struct RedeemParams {
        address account;
        address receiver;
        uint256 strategyTokens;
        uint256 maturity;
        int256 assetInternalToRepayDebt;
    }
    /// @notice This will call the strategy vault and have it redeem the specified amount of strategy tokens
    /// for underlying. The amount of underlying required to repay the debt will be transferred back to the protocol
    /// and any excess will be returned to the account. If the account does not redeem sufficient strategy tokens to repay
    /// debts then this method will attempt to recover the remaining underlying tokens from the account directly.
    /// @param vaultConfig vault config
    /// @param params redemption parameters
    /// @param data arbitrary data to pass to the vault
    /// @return assetCashInternalRaised the amount of asset cash (positive) that was returned to repay debts
    function _redeem(
        VaultConfig memory vaultConfig,
        RedeemParams memory params,
        bytes calldata data
    ) internal returns (int256) {
        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // If the asset token is NonMintable then the underlying is the same object.
        Token memory underlyingToken = assetToken.tokenType == TokenType.NonMintable ? 
            assetToken :
            TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);

        // Calculates the amount of underlying tokens required to repay the debt, adjusting for potential
        // dust values.
        uint256 underlyingExternalToRepay;
        if (params.assetInternalToRepayDebt < 0) {
            if (assetToken.tokenType == TokenType.NonMintable) {
                // NonMintable token amounts are exact and don't require any asset rate conversions or adjustments
                underlyingExternalToRepay = params.assetInternalToRepayDebt.neg().toUint();
            } else {
                // Mintable tokens require an off by one adjustment to account for rounding errors between
                // transfer and minting
                int256 x = vaultConfig.assetRate.convertToUnderlying(params.assetInternalToRepayDebt).neg();
                underlyingExternalToRepay = underlyingToken.convertToUnderlyingExternalWithAdjustment(x).toUint();
            }
        }

        uint256 amountTransferred;
        if (params.strategyTokens > 0) {
            uint256 balanceBefore = underlyingToken.balanceOf(address(this));
            // The vault will either transfer underlyingExternalToRepay back to Notional or it will
            // transfer all the underlying tokens it has redeemed and we will have to recover any remaining
            // underlying from the account directly.
            IStrategyVault(vaultConfig.vault).redeemFromNotional(
                params.account, params.receiver, params.strategyTokens, params.maturity, underlyingExternalToRepay, data
            );
            uint256 balanceAfter = underlyingToken.balanceOf(address(this));
            amountTransferred = balanceAfter.sub(balanceBefore);
        }

        if (amountTransferred < underlyingExternalToRepay) {
            // Recover any unpaid debt amount from the account directly
            uint256 residualRequired = underlyingExternalToRepay - amountTransferred;

            // Since ETH does not allow pull payment, the account needs to transfer sufficient
            // ETH to repay the debt. We don't use WETH here since the rest of Notional does not
            // use WETH. Any residual ETH is transferred back to the account. Vault actions that
            // do not repay debt during redeem will not enter this code block.
            if (underlyingToken.tokenType == TokenType.Ether) {
                require(residualRequired <= msg.value, "Insufficient repayment");
                // Transfer out the unused part of msg.value, we've received all underlying external required
                // at this point
                GenericToken.transferNativeTokenOut(params.account, msg.value - residualRequired);
                amountTransferred = underlyingExternalToRepay;
            } else {
                // actualTransferExternal is a positive number here to signify assets have entered
                // the protocol
                int256 actualTransferExternal = underlyingToken.transfer(
                    params.account, vaultConfig.borrowCurrencyId, residualRequired.toInt()
                );
                amountTransferred = amountTransferred.add(actualTransferExternal.toUint());
            }
        }
        require(amountTransferred >= underlyingExternalToRepay, "Insufficient repayment");

        // NonMintable tokens do not need to be minted, the amount transferred is the amount
        // of asset cash raised.
        int256 assetCashExternal = assetToken.tokenType == TokenType.NonMintable ?
            amountTransferred.toInt() :
            assetToken.mint(vaultConfig.borrowCurrencyId, amountTransferred);

        // Due to the adjustment in underlyingExternalToRepay, this returns a dust amount more
        // than the value of assetInternalToRepayDebt.
        return assetToken.convertToInternal(assetCashExternal);
    }

    /// @notice Resolves any shortfalls using the protocol reserve. Pauses the vault so that no
    /// further vault entries are possible. If the reserve is insufficient to recover the shortfall
    /// then the shortfall must be resolved via governance action.
    /// Vaults that borrow in secondary currencies must first attempt to repay secondary currencies
    /// in their entirety and push the insolvency onto the primary currency as much as possible. If
    /// there is an insolvency in a secondary currency then it must be resolved via governance action.
    /// @param vault the vault where the shortfall has occurred
    /// @param currencyId the primary currency id of the vault
    /// @param assetCashShortfall amount of asset cash internal for the shortfall
    /// @return assetCashRaised from the cash reserve, may not be sufficient to cover the shortfall
    function resolveShortfallWithReserve(
        address vault,
        uint16 currencyId,
        int256 assetCashShortfall
    ) internal returns (int256 assetCashRaised) {
        // If there is any cash shortfall, we automatically disable the vault. Accounts can still
        // exit but no one can enter. Governance can re-enable the vault.
        setVaultEnabledStatus(vault, false);
        emit VaultPauseStatus(vault, false);
        emit VaultShortfall(currencyId, vault, assetCashShortfall);

        // Attempt to resolve the cash balance using the reserve
        (int256 reserveInternal, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(
            Constants.RESERVE, currencyId
        );

        if (assetCashShortfall <= reserveInternal) {
            BalanceHandler.setReserveCashBalance(currencyId, reserveInternal - assetCashShortfall);
            assetCashRaised = assetCashShortfall;
        } else {
            // At this point the protocol needs to raise funds from sNOTE since the reserve is
            // insufficient to cover
            BalanceHandler.setReserveCashBalance(currencyId, 0);
            emit ProtocolInsolvency(currencyId, vault, assetCashShortfall - reserveInternal);
            assetCashRaised = reserveInternal;
        }
    }
}