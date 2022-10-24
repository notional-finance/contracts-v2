// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {DateTime} from "../markets/DateTime.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TradingAction} from "../../external/actions/TradingAction.sol";
import {ExchangeRate} from "../valuation/ExchangeRate.sol";
import {DateTime} from "../markets/DateTime.sol";
import {CashGroup, CashGroupParameters, Market, MarketParameters} from "../markets/CashGroup.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {Token, TokenType, TokenHandler} from "../balances/TokenHandler.sol";
import {GenericToken} from "../balances/protocols/GenericToken.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";

import {
    VaultConfig,
    VaultAccount,
    VaultConfigStorage,
    VaultBorrowCapacityStorage,
    VaultSecondaryBorrowStorage,
    VaultAccountSecondaryDebtShareStorage,
    TradeActionType,
    ETHRate
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
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;

    /// @notice Emitted when a vault fee is accrued via borrowing (denominated in asset cash)
    event VaultFeeAccrued(address indexed vault, uint16 indexed currencyId, uint256 indexed maturity, int256 reserveFee, int256 nTokenFee);
    /// @notice Emitted when the borrow capacity on a vault changes
    event VaultBorrowCapacityChange(address indexed vault, uint16 indexed currencyId, uint256 totalUsedBorrowCapacity);

    /// @notice Emitted when a vault executes a secondary borrow
    event VaultSecondaryBorrow(
        address indexed vault,
        address indexed account,
        uint16 indexed currencyId,
        uint256 maturity,
        uint256 debtSharesMinted,
        uint256 fCashBorrowed
    );

    /// @notice Emitted when a vault repays a secondary borrow
    event VaultRepaySecondaryBorrow(
        address indexed vault,
        address indexed account,
        uint16 indexed currencyId,
        uint256 maturity,
        uint256 debtSharesRepaid,
        uint256 fCashLent
    );

    /// @notice Emitted when secondary borrows are snapshot prior to settlement
    event VaultSecondaryBorrowSnapshot(
        address indexed vault,
        uint16 indexed currencyId,
        uint256 indexed maturity,
        int256 totalfCashBorrowedInPrimarySnapshot,
        int256 exchangeRate
    );

    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address indexed vault, bool enabled);
    /// @notice Emitted when a vault has a shortfall upon settlement
    event VaultShortfall(
        address indexed vault,
        uint16 indexed currencyId,
        uint256 indexed maturity,
        int256 shortfall
    );
    /// @notice Emitted when a vault has an insolvency that cannot be covered by the
    /// cash reserve
    event ProtocolInsolvency(
        address indexed vault,
        uint16 indexed currencyId,
        uint256 indexed maturity,
        int256 shortfall
    );

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
    uint16 internal constant DISABLE_DELEVERAGE              = 1 << 8;

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
        vaultConfig.maxRequiredAccountCollateralRatio = int256(uint256(s.maxRequiredAccountCollateralRatioBPS).mul(Constants.BASIS_POINT));
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

    function setVaultDeleverageStatus(address vaultAddress, bool disableDeleverage) internal {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfigStorage storage s = store[vaultAddress];
        uint16 flags = s.flags;

        if (disableDeleverage) {
            s.flags = flags | VaultConfiguration.DISABLE_DELEVERAGE;
        } else {
            s.flags = flags & ~VaultConfiguration.DISABLE_DELEVERAGE;
        }
    }

    function setVaultConfig(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig
    ) internal {
        mapping(address => VaultConfigStorage) storage store = LibStorage.getVaultConfig();
        VaultConfig memory existingVaultConfig = _getVaultConfig(vaultAddress);
        // Cannot change borrow currency once set
        require(vaultConfig.borrowCurrencyId != 0);
        require(existingVaultConfig.borrowCurrencyId == 0 || existingVaultConfig.borrowCurrencyId == vaultConfig.borrowCurrencyId);

        // Liquidation rate must be greater than or equal to 100
        require(Constants.PERCENTAGE_DECIMALS <= vaultConfig.liquidationRate);
        // minCollateralRatioBPS to RATE_PRECISION is minCollateralRatioBPS * BASIS_POINT (1e5)
        // liquidationRate to RATE_PRECISION  is liquidationRate * RATE_PRECISION / PERCENTAGE_DECIMALS (net 1e7)
        //    (liquidationRate - 100) * 1e9 / 1e2 < minCollateralRatioBPS * 1e5
        //    (liquidationRate - 100) * 1e2 < minCollateralRatioBPS
        uint16 liquidationRate = uint16(
            uint256(vaultConfig.liquidationRate - uint256(Constants.PERCENTAGE_DECIMALS)) * uint256(1e2)
        );
        // Ensure that liquidation rate is less than minCollateralRatio so that liquidations are not locked
        // up causing accounts to remain insolvent
        require(liquidationRate < vaultConfig.minCollateralRatioBPS);

        // Collateral ratio values must satisfy this inequality:
        // insolvent < 0 < [liquidatable account] <  ...
        //      minCollateralRatio < [account] < maxDeleverageCollateralRatio < ...
        //      [account] < maxRequiredAccountCollateralRatio

        // This must be true or else when deleveraging we could put an account further towards insolvency
        require(vaultConfig.minCollateralRatioBPS < vaultConfig.maxDeleverageCollateralRatioBPS);
        // This must be true or accounts cannot enter the vault
        require(vaultConfig.maxDeleverageCollateralRatioBPS < vaultConfig.maxRequiredAccountCollateralRatioBPS);

        // Reserve fee share must be less than or equal to 100
        require(vaultConfig.reserveFeeShare <= Constants.PERCENTAGE_DECIMALS);
        require(vaultConfig.maxBorrowMarketIndex != 0);

        // Secondary borrow currencies cannot change once set
        require(
            existingVaultConfig.secondaryBorrowCurrencies[0] == 0 ||
            existingVaultConfig.secondaryBorrowCurrencies[0] == vaultConfig.secondaryBorrowCurrencies[0]
        );
        require(
            existingVaultConfig.secondaryBorrowCurrencies[1] == 0 ||
            existingVaultConfig.secondaryBorrowCurrencies[1] == vaultConfig.secondaryBorrowCurrencies[1]
        );

        // The borrow currency cannot be duplicated as a secondary borrow currency
        require(vaultConfig.borrowCurrencyId != vaultConfig.secondaryBorrowCurrencies[0]);
        require(vaultConfig.borrowCurrencyId != vaultConfig.secondaryBorrowCurrencies[1]);
        if (vaultConfig.secondaryBorrowCurrencies[0] != 0 && vaultConfig.secondaryBorrowCurrencies[1] != 0) {
            // Check that these values are not duplicated if set
            require(vaultConfig.secondaryBorrowCurrencies[0] != vaultConfig.secondaryBorrowCurrencies[1]);
        }

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

    function hasSecondaryBorrows(VaultConfig memory vaultConfig) internal pure returns (bool) {
        return vaultConfig.secondaryBorrowCurrencies[0] != 0 || vaultConfig.secondaryBorrowCurrencies[1] != 0;
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
    /// @param assetCashBorrowed the amount of cash the account has borrowed
    /// @param maturity maturity of fCash
    /// @param blockTime current block time
    function assessVaultFees(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        int256 assetCashBorrowed,
        uint256 maturity,
        uint256 blockTime
    ) internal {
        // The fee rate is annualized, we prorate it linearly based on the time to maturity here
        int256 proratedFeeRate = vaultConfig.feeRate
            .mul(maturity.sub(blockTime).toInt())
            .div(int256(Constants.YEAR));

        int256 netTotalFee = assetCashBorrowed.mulInRatePrecision(proratedFeeRate);

        // Reserve fee share is restricted to less than 100
        int256 reserveFee = netTotalFee.mul(vaultConfig.reserveFeeShare).div(Constants.PERCENTAGE_DECIMALS);
        int256 nTokenFee = netTotalFee.sub(reserveFee);

        BalanceHandler.incrementFeeToReserve(vaultConfig.borrowCurrencyId, reserveFee);
        BalanceHandler.incrementVaultFeeToNToken(vaultConfig.borrowCurrencyId, nTokenFee);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.sub(netTotalFee);
        emit VaultFeeAccrued(vaultConfig.vault, vaultConfig.borrowCurrencyId, maturity, reserveFee, nTokenFee);
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
        // overflow already checked above
        emit VaultBorrowCapacityChange(vault, currencyId, uint256(totalUsedBorrowCapacity));
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

        // This value is the total amount of fCash borrowed in secondary currencies denominated in the
        // primary borrow currency as a positive integer.
        int256 secondaryDebtOutstanding = _getSecondaryDebtOutstanding(vaultConfig, account, vaultState.maturity);

        // We do not discount fCash to present value so that we do not introduce interest
        // rate risk in this calculation. The economic benefit of discounting will be very
        // minor relative to the added complexity of accounting for interest rate risk.

        // Convert fCash to a positive amount of asset cash
        int256 debtOutstanding = vaultConfig.assetRate.convertFromUnderlying(fCash.neg().add(secondaryDebtOutstanding));

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

    /**
     * @notice Returns the total fCash borrowed in primary currency terms between both secondary
     * borrow currencies (if they are configured).
     */
    function _getSecondaryDebtOutstanding(
        VaultConfig memory vaultConfig,
        address account,
        uint256 maturity
    ) private view returns (int256 totalfCashBorrowedInPrimary) {
        if (hasSecondaryBorrows(vaultConfig)) {
            VaultAccountSecondaryDebtShareStorage storage s = 
                LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];
            ETHRate memory primaryER = ExchangeRate.buildExchangeRate(vaultConfig.borrowCurrencyId);
            uint256 accountDebtSharesOne = s.accountDebtSharesOne;
            uint256 accountDebtSharesTwo = s.accountDebtSharesTwo;

            if (accountDebtSharesOne > 0) {
                totalfCashBorrowedInPrimary = totalfCashBorrowedInPrimary.add(_calculateSecondaryDebt(
                    primaryER, vaultConfig.secondaryBorrowCurrencies[0], vaultConfig.vault, maturity, accountDebtSharesOne
                ));
            }

            if (accountDebtSharesTwo > 0) {
                totalfCashBorrowedInPrimary = totalfCashBorrowedInPrimary.add(_calculateSecondaryDebt(
                    primaryER, vaultConfig.secondaryBorrowCurrencies[1], vaultConfig.vault, maturity, accountDebtSharesTwo
                ));
            }
        }
    }

    /**
     * @notice Calculates the amount of secondary debt borrowed by an account in primary currency terms.
     */
    function _calculateSecondaryDebt(
        ETHRate memory primaryER,
        uint16 currencyId,
        address vault,
        uint256 maturity,
        uint256 accountDebtShares
    ) private view returns (int256 fCashBorrowedInPrimary) {
        VaultSecondaryBorrowStorage storage balance = LibStorage.getVaultSecondaryBorrow()
            [vault][maturity][currencyId];
        uint256 totalfCashBorrowed = balance.totalfCashBorrowed;
        uint256 totalAccountDebtShares = balance.totalAccountDebtShares;
        
        int256 fCashBorrowed = accountDebtShares.mul(totalfCashBorrowed).div(totalAccountDebtShares).toInt();
        ETHRate memory secondaryER = ExchangeRate.buildExchangeRate(currencyId);
        int256 exchangeRate = ExchangeRate.exchangeRate(primaryER, secondaryER);
        fCashBorrowedInPrimary = fCashBorrowed.mul(primaryER.rateDecimals).div(exchangeRate);
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

        // Enforce a maximum account collateral ratio that must be satisfied for vault entry and vault exit,
        // to ensure that accounts are not "free riding" on vaults by entering without incurring borrowing
        // costs. We only enforce this if the account has any assets remaining in the vault (so that they
        // may exit in full at any time.)
        if (vaultAccount.vaultShares > 0) {
            require(collateralRatio <= vaultConfig.maxRequiredAccountCollateralRatio, "Above Max Collateral");
        }

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
        // Tokens with transfer fees are not allowed in vaults
        require(!underlyingToken.hasTransferFee);
        if (underlyingToken.tokenType == TokenType.Ether) {
            require(msg.value == depositAmountExternal, "Invalid ETH");
            // Forward all the ETH to the vault
            GenericToken.transferNativeTokenOut(vault, msg.value);

            return msg.value;
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
    ) internal returns (int256 assetCashInternalRaised, uint256 underlyingToReceiver) {
        // Asset cash internal raised is only used by the vault, in all other cases it
        // should return 0
        (assetCashInternalRaised, underlyingToReceiver) = _redeem(
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
    ) internal returns (uint256 underlyingToReceiver) {
        require(vaultAccount.tempCashBalance <= 0);
        // This method will revert if the tempCashBalance is not repaid, although the return value will be greater
        // than tempCashBalance due to rounding adjustments. Just clear tempCashBalance to remove the dust from
        // internal accounting (the dust will accrue to the protocol).
        (/* */, underlyingToReceiver) = _redeem(
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
    /// @return underlyingToReceiver the amount of underlying that was returned to the receiver from the vault
    function _redeem(
        VaultConfig memory vaultConfig,
        RedeemParams memory params,
        bytes calldata data
    ) internal returns (int256 assetCashInternalRaised, uint256 underlyingToReceiver) {
        (Token memory assetToken, Token memory underlyingToken) = getTokens(vaultConfig);

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
            // There are four possibilities here during the transfer:
            //   1. If the account == vaultConfig.vault then the strategy vault must always transfer
            //      tokens back to Notional. underlyingToReceiver will equal 0, amountTransferred will
            //      be the value of the redemption.
            //   2. If the account has debt to repay and is redeeming sufficient tokens to repay the debt,
            //      the vault will transfer back underlyingExternalToRepay and transfer underlyingToReceiver
            //      directly to the receiver.
            //   3. If the account has redeemed insufficient tokens to repay the debt, the vault will transfer
            //      back as much as it can (less than underlyingExternalToRepay) and underlyingToReceiver will
            //      be zero. If this occurs, then the next if block will be triggered where we attempt to recover
            //      the shortfall from the account's wallet.
            //   4. During liquidation, the liquidator will redeem their strategy token profits without any debt
            //      to repay (underlyingExternalToRepay == 0). This means that all the profits will be returned
            //      to the liquidator (params.receiver) from the vault (underlyingToReceiver will be the full value
            //      of the redemption) and amountTransferred will equal 0. A similar scenario will occur when
            //      accounts exit post maturity and have no debt associated with their account.
            underlyingToReceiver = IStrategyVault(vaultConfig.vault).redeemFromNotional(
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
        // amountTransferred should never be much more than underlyingExternalToRepay (it should
        // be exactly equal) as long as the vault behaves according to spec.
        require(amountTransferred >= underlyingExternalToRepay, "Insufficient repayment");

        // NonMintable tokens do not need to be minted, the amount transferred is the amount
        // of asset cash raised.
        int256 assetCashExternal;
        if (assetToken.tokenType == TokenType.NonMintable) {
            assetCashExternal = amountTransferred.toInt();
        } else if (amountTransferred > 0) {
            assetCashExternal = assetToken.mint(vaultConfig.borrowCurrencyId, amountTransferred);
        }

        // Due to the adjustment in underlyingExternalToRepay, this returns a dust amount more
        // than the value of assetInternalToRepayDebt. This value is only used when we are
        // redeeming strategy tokens to the vault.
        assetCashInternalRaised = assetToken.convertToInternal(assetCashExternal);
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
        int256 assetCashShortfall,
        uint256 maturity
    ) internal returns (int256 assetCashRaised) {
        // If there is any cash shortfall, we automatically disable the vault. Accounts can still
        // exit but no one can enter. Governance can re-enable the vault.
        setVaultEnabledStatus(vault, false);
        emit VaultPauseStatus(vault, false);
        emit VaultShortfall(vault, currencyId, maturity, assetCashShortfall);

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
            emit ProtocolInsolvency(vault, currencyId, maturity, assetCashShortfall - reserveInternal);
            assetCashRaised = reserveInternal;
        }
    }

    /// @notice Increases the used capacity on a secondary borrow, tracks the accountDebtShares when individual
    /// accounts are borrowing so that we can later calculate the proper amount of secondary fCash they need
    /// to repay.
    /// @param vaultConfig vault config
    /// @param account address of account executing the secondary borrow (this may be the vault itself)
    /// @param currencyId relevant currency id
    /// @param maturity the maturity of the fCash
    /// @param fCashToBorrow amount of fCash to borrow
    /// @param maxBorrowRate maximum annualized rate of fCash to borrow
    /// @return netAssetCash a positive amount of asset cash to transfer
    function increaseSecondaryBorrow(
        VaultConfig memory vaultConfig,
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint32 maxBorrowRate
    ) internal returns (int256 netAssetCash, uint256 accountDebtShares) {
        // Vaults cannot initiate borrows, only repayments
        require(account != vaultConfig.vault);
        // This will revert if we overflow the maximum borrow capacity, expects a negative fCash value when borrowing
        updateUsedBorrowCapacity(vaultConfig.vault, currencyId, fCashToBorrow.toInt().neg());

        // Updates storage for the specific maturity so we can track this on chain.
        VaultSecondaryBorrowStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vaultConfig.vault][maturity][currencyId];
        require(!balance.hasSnapshotBeenSet, "In Settlement");
        uint256 totalfCashBorrowed = balance.totalfCashBorrowed;
        uint256 totalAccountDebtShares = balance.totalAccountDebtShares;

        // After this point, (accountDebtShares * totalfCashBorrowed) / totalDebtShares = fCashToBorrow
        // therefore: accountfCashShares = (netfCash * totalfCashShares) / totalfCashBorrowed
        if (totalfCashBorrowed == 0) {
            accountDebtShares = fCashToBorrow;
        } else {
            accountDebtShares = fCashToBorrow.mul(totalAccountDebtShares).div(totalfCashBorrowed);
        }

        _updateAccountDebtShares(
            vaultConfig, account, currencyId, maturity, accountDebtShares.toInt()
        );
        balance.totalAccountDebtShares = totalAccountDebtShares.add(accountDebtShares).toUint80();
        balance.totalfCashBorrowed = totalfCashBorrowed.add(fCashToBorrow).toUint80();

        netAssetCash = _executeSecondaryCurrencyTrade(
            vaultConfig, currencyId, maturity, fCashToBorrow.toInt().neg(), maxBorrowRate
        );

        emit VaultSecondaryBorrow(vaultConfig.vault, account, currencyId, maturity, accountDebtShares, fCashToBorrow);
    }

    /// @notice Decreases the used capacity on a secondary borrow based on debt shares
    /// @param vaultConfig vault config
    /// @param account address of account executing the secondary borrow (this may be the vault itself)
    /// @param currencyId relevant currency id
    /// @param maturity the maturity of the fCash
    /// @param debtSharesToRepay amount of debt shares to repay
    /// @return netAssetCash a negative amount of asset cash required to repay
    function repaySecondaryBorrow(
        VaultConfig memory vaultConfig,
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 debtSharesToRepay,
        uint32 minLendRate
    ) internal returns (int256 netAssetCash, int256 fCashToLend) {
        // Updates storage for the specific maturity so we can track this on chain.
        VaultSecondaryBorrowStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vaultConfig.vault][maturity][currencyId];

        // Once a secondary borrow is in settlement, only the vault can initiate repayment
        require(!balance.hasSnapshotBeenSet || account == vaultConfig.vault, "In Settlement");
        uint256 totalfCashBorrowed = balance.totalfCashBorrowed;
        uint256 totalAccountDebtShares = balance.totalAccountDebtShares;

        // Debt shares to repay is never zero based on the calling method, so we do not encounter divide
        // by zero issues here (if we did, it would be a critical accounting issue)
        fCashToLend = debtSharesToRepay.mul(totalfCashBorrowed).div(totalAccountDebtShares).toInt();

        if (account != vaultConfig.vault) {
            // We only burn the total debt shares if it is an individual account repaying the debt
            balance.totalAccountDebtShares = totalAccountDebtShares.sub(debtSharesToRepay).toUint80();
            _updateAccountDebtShares(
                vaultConfig, account, currencyId, maturity, debtSharesToRepay.toInt().neg()
            );
        }

        // Update the global counters
        updateUsedBorrowCapacity(vaultConfig.vault, currencyId, fCashToLend);
        // Will revert if this underflows zero (cannot overflow uint256, known to be positive from above)
        balance.totalfCashBorrowed = totalfCashBorrowed.sub(uint256(fCashToLend)).toUint80();

        netAssetCash = _executeSecondaryCurrencyTrade(
            vaultConfig, currencyId, maturity, fCashToLend, minLendRate
        );

        emit VaultRepaySecondaryBorrow(vaultConfig.vault, account, currencyId, maturity, debtSharesToRepay, uint256(fCashToLend));
    }

    /**
     * @notice Takes a snapshot of the secondary borrow currencies at settlement, can only be initiated by the
     * vault itself. This is required to get an accurate accounting of vault share value at settlement (since
     * strategy tokens are also sold to repay accountDebtShares). Once a snapshot has been taken, no secondary
     * borrows or repayments can occur.
     * @param vaultConfig vault configuration
     * @param currencyId secondary currency to snapshot
     * @param maturity maturity to snapshot
     * @return totalfCashBorrowedInPrimary the total fCash borrowed in this currency converted to the primary currency
     * at the current oracle exchange rate
     */
    function snapshotSecondaryBorrowAtSettlement(
        VaultConfig memory vaultConfig,
        uint16 currencyId,
        uint256 maturity
    ) internal returns (int256 totalfCashBorrowedInPrimary) {
        if (currencyId == 0) return 0;

        // Updates storage for the specific maturity so we can track this on chain.
        VaultSecondaryBorrowStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vaultConfig.vault][maturity][currencyId];
        // The snapshot value can only be set once when settlement is initiated
        require(!balance.hasSnapshotBeenSet, "Cannot Reset Snapshot");

        int256 totalfCashBorrowed = int256(uint256(balance.totalfCashBorrowed));
        ETHRate memory primaryER = ExchangeRate.buildExchangeRate(vaultConfig.borrowCurrencyId);
        ETHRate memory secondaryER = ExchangeRate.buildExchangeRate(currencyId);
        int256 exchangeRate = ExchangeRate.exchangeRate(primaryER, secondaryER);
        
        // Converts totafCashBorrowed (in secondary, underlying) to primary underlying via ETH exchange rates
        totalfCashBorrowedInPrimary = totalfCashBorrowed.mul(primaryER.rateDecimals).div(exchangeRate);
        balance.totalfCashBorrowedInPrimarySnapshot = totalfCashBorrowedInPrimary.toUint().toUint80();
        balance.hasSnapshotBeenSet = true;

        emit VaultSecondaryBorrowSnapshot(
            vaultConfig.vault, currencyId, maturity, totalfCashBorrowedInPrimary, exchangeRate
        );
    }

    function _updateAccountDebtShares(
        VaultConfig memory vaultConfig,
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 netAccountDebtShares
    ) private {
        VaultAccountSecondaryDebtShareStorage storage s = 
            LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];
        uint256 accountMaturity = s.maturity;
        require(accountMaturity == maturity || accountMaturity == 0, "Invalid Secondary Maturity");
        int256 accountDebtSharesOne = int256(uint256(s.accountDebtSharesOne));
        int256 accountDebtSharesTwo = int256(uint256(s.accountDebtSharesTwo));

        if (currencyId == vaultConfig.secondaryBorrowCurrencies[0]) {
            accountDebtSharesOne = accountDebtSharesOne.add(netAccountDebtShares);
            s.accountDebtSharesOne = accountDebtSharesOne.toUint().toUint80();
        } else if (currencyId == vaultConfig.secondaryBorrowCurrencies[1]) {
            accountDebtSharesTwo = accountDebtSharesTwo.add(netAccountDebtShares);
            s.accountDebtSharesTwo = accountDebtSharesTwo.toUint().toUint80();
        } else {
            // This should never occur due to previous validation
            revert();
        }

        if (accountDebtSharesOne == 0 && accountDebtSharesTwo == 0) {
            // If both debt shares are cleared to zero, clear the maturity as well.
            s.maturity = 0;
        } else if (accountMaturity == 0) {
            // Set the maturity if it is cleared
            s.maturity = maturity.toUint40();
        }
    }

    /// @notice Executes a secondary currency lend or borrow
    function _executeSecondaryCurrencyTrade(
        VaultConfig memory vaultConfig,
        uint16 currencyId,
        uint256 maturity,
        int256 netfCash,
        uint32 slippageLimit
    ) private returns (int256 netAssetCash) {
        require(currencyId != vaultConfig.borrowCurrencyId);
        if (netfCash == 0) return 0;

        if (maturity <= block.timestamp) {
            // Cannot borrow after maturity
            require(netfCash >= 0);

            // Post maturity, repayment must be done via the settlement rate
            AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
                currencyId, maturity, block.timestamp
            );
            netAssetCash = settlementRate.convertFromUnderlying(netfCash).neg();
        } else {
            netAssetCash = executeTrade(
                currencyId,
                maturity,
                netfCash,
                slippageLimit,
                vaultConfig.maxBorrowMarketIndex,
                block.timestamp
            );

            // If netAssetCash is zero then the contract must lend at 0% interest using the asset cash
            // exchange rate. In this case, the vault forgoes any money market interest on asset cash
            if (netfCash > 0 && netAssetCash == 0) {
                netAssetCash = vaultConfig.assetRate.convertFromUnderlying(netfCash).neg();
            }

            // Require that borrows always succeed
            if (netfCash < 0) require(netAssetCash > 0, "Borrow Failed");
        }
    }

    /// @notice Executes a trade on the AMM.
    /// @param currencyId id of the vault borrow currency
    /// @param maturity maturity to lend or borrow at
    /// @param netfCashToAccount positive if lending, negative if borrowing
    /// @param rateLimit 0 if there is no limit, otherwise is a slippage limit
    /// @param blockTime current time
    /// @return netAssetCash amount of cash to credit to the account
    function executeTrade(
        uint16 currencyId,
        uint256 maturity,
        int256 netfCashToAccount,
        uint32 rateLimit,
        uint256 maxBorrowMarketIndex,
        uint256 blockTime
    ) internal returns (int256 netAssetCash) {
        uint256 marketIndex = checkValidMaturity(currencyId, maturity, maxBorrowMarketIndex, blockTime);
        // fCash is restricted from being larger than uint88 inside the trade module
        uint256 fCashAmount = uint256(netfCashToAccount.abs());
        require(fCashAmount < type(uint88).max);

        // Encodes trade data for the TradingAction module
        bytes32 trade = bytes32(
            (uint256(uint8(netfCashToAccount > 0 ? TradeActionType.Lend : TradeActionType.Borrow)) << 248) |
            (uint256(marketIndex) << 240) |
            (uint256(fCashAmount) << 152) |
            (uint256(rateLimit) << 120)
        );

        // Use the library here to reduce the deployed bytecode size
        netAssetCash = TradingAction.executeVaultTrade(currencyId, trade);
    }
    
    function checkValidMaturity(
        uint16 currencyId,
        uint256 maturity,
        uint256 maxBorrowMarketIndex,
        uint256 blockTime
    ) internal view returns (uint256 marketIndex) {
        bool isIdiosyncratic;
        uint8 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        (marketIndex, isIdiosyncratic) = DateTime.getMarketIndex(maxMarketIndex, maturity, blockTime);
        require(marketIndex <= maxBorrowMarketIndex, "Invalid Maturity");
        require(!isIdiosyncratic, "Invalid Maturity");
    }

    function getTokens(VaultConfig memory vaultConfig) internal view returns (
        Token memory assetToken,
        Token memory underlyingToken
    ) {
        assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // If the asset token is NonMintable then the underlying is the same object.
        underlyingToken = assetToken.tokenType == TokenType.NonMintable ? 
            assetToken :
            TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
    }
}