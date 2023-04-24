// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultConfig,
    VaultAccount,
    VaultConfigStorage,
    VaultBorrowCapacityStorage,
    TradeActionType,
    PrimeRate,
    Token,
    TokenType,
    VaultState
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {Emitter} from "../Emitter.sol";
import {DateTime} from "../markets/DateTime.sol";
import {CashGroup} from "../markets/CashGroup.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {TokenHandler} from "../balances/TokenHandler.sol";
import {GenericToken} from "../balances/protocols/GenericToken.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";
import {VaultStateLib} from "./VaultState.sol";

import {TradingAction} from "../../external/actions/TradingAction.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";
import {IERC20} from "../../../interfaces/IERC20.sol";

/// @notice Vault configuration holds per vault parameters and methods that interact
/// with vault level parameters (such as fee assessments, collateral ratios, capacity
/// limits, etc.)
library VaultConfiguration {
    using TokenHandler for Token;
    using VaultStateLib for VaultState;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using PrimeRateLib for PrimeRate;

    /// @notice Emitted when the borrow capacity on a vault changes
    event VaultBorrowCapacityChange(address indexed vault, uint16 indexed currencyId, uint256 totalUsedBorrowCapacity);
    /// @notice Emitted when a vault's status is updated
    event VaultPauseStatus(address indexed vault, bool enabled);

    uint16 internal constant ENABLED                         = 1 << 0;
    uint16 internal constant ALLOW_ROLL_POSITION             = 1 << 1;
    // These flags switch the authentication on the vault methods such that all
    // calls must come from the vault itself.
    uint16 internal constant ONLY_VAULT_ENTRY                = 1 << 2;
    uint16 internal constant ONLY_VAULT_EXIT                 = 1 << 3;
    uint16 internal constant ONLY_VAULT_ROLL                 = 1 << 4;
    uint16 internal constant ONLY_VAULT_DELEVERAGE           = 1 << 5;
    uint16 internal constant VAULT_MUST_SETTLE               = 1 << 6;
    // External vault methods will have re-entrancy protection on by default, however, some
    // vaults may need to call back into Notional so we can whitelist them for re-entrancy.
    uint16 internal constant ALLOW_REENTRANCY                = 1 << 7;
    uint16 internal constant DISABLE_DELEVERAGE              = 1 << 8;
    // Enables fCash discounting during vault valuation. While this allows more leverage for
    // accounts in the vault, it also exposes accounts to potential liquidation due to interest
    // rate changes on Notional. While this is desireable in some vaults that explicitly target
    // interest rate arbitrage, it may create UX issues for other vaults that are more passive.
    // When this flag is set to false, fCash is not discounted to present value so that it holds
    // zero interest rate risk.
    uint16 internal constant ENABLE_FCASH_DISCOUNT           = 1 << 9;

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
        vaultConfig.minAccountSecondaryBorrow[0] = int256(uint256(s.minAccountSecondaryBorrow[0])).mul(Constants.INTERNAL_TOKEN_PRECISION);
        vaultConfig.minAccountSecondaryBorrow[1] = int256(uint256(s.minAccountSecondaryBorrow[1])).mul(Constants.INTERNAL_TOKEN_PRECISION);
    }

    function getVaultConfigNoPrimeRate(
        address vaultAddress
    ) internal view returns (VaultConfig memory vaultConfig) {
        vaultConfig = _getVaultConfig(vaultAddress);
    }

    function getVaultConfigStateful(
        address vaultAddress
    ) internal returns (VaultConfig memory vaultConfig) {
        vaultConfig = _getVaultConfig(vaultAddress);
        vaultConfig.primeRate = PrimeRateLib.buildPrimeRateStateful(vaultConfig.borrowCurrencyId);
    }

    function getVaultConfigView(
        address vaultAddress
    ) internal view returns (VaultConfig memory vaultConfig) {
        vaultConfig = _getVaultConfig(vaultAddress);
        (vaultConfig.primeRate, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(
            vaultConfig.borrowCurrencyId, block.timestamp
        );
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
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
        require(!underlyingToken.hasTransferFee); 

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

    /// @notice Returns true if a vault config has secondary borrows
    function hasSecondaryBorrows(VaultConfig memory vaultConfig) internal pure returns (bool) {
        return vaultConfig.secondaryBorrowCurrencies[0] != 0 || vaultConfig.secondaryBorrowCurrencies[1] != 0;
    }

    function calculateVaultFees(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        int256 primeCashBorrowed,
        uint256 maturity,
        uint256 blockTime
    ) internal pure returns (int256 netTotalFee) {
        int256 proratedFeeTime;
        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // vaultAccount.maturity is set after assessVaultFees on the initial entry
            // to the prime cash maturity, so if it is not set here then we do not
            // assess a fee on the vault account. The fee for its initial period will
            // be assessed on the next time it borrows more or exits the vaults.
            if (vaultAccount.maturity != Constants.PRIME_CASH_VAULT_MATURITY) return 0;

            // Prime cash vaults do not have a maturity, so accounts are assessed
            // a fee based on how long they have borrowed from the vault.
            // proratedFeeTime = (blockTime - lastUpdateBlockTime)
            // NOTE: this means fees must be assessed on exit and entry
            proratedFeeTime = blockTime.sub(vaultAccount.lastUpdateBlockTime).toInt();
            // Set the timer here so that we do not double assess fees later
            vaultAccount.lastUpdateBlockTime = blockTime;
        } else {
            proratedFeeTime = maturity.sub(blockTime).toInt();
        }

        // The fee rate is annualized, we prorate it linearly based on the time to maturity here
        int256 proratedFeeRate = vaultConfig.feeRate
            .mul(proratedFeeTime)
            .div(int256(Constants.YEAR));

        netTotalFee = primeCashBorrowed.mulInRatePrecision(proratedFeeRate);
    }

    /// @notice Assess fees to the vault account. The fee based on time to maturity and the amount of fCash. Fees
    /// will be accrued to the nToken cash balance and the protocol cash reserve.
    /// @param vaultConfig vault configuration
    /// @param vaultAccount modifies the vault account temp cash balance in memory
    /// @param primeCashBorrowed the amount of cash the account has borrowed
    /// @param maturity maturity of fCash
    /// @param blockTime current block time
    function assessVaultFees(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        int256 primeCashBorrowed,
        uint256 maturity,
        uint256 blockTime
    ) internal returns (int256 netTotalFee) {
        netTotalFee = calculateVaultFees(vaultConfig, vaultAccount, primeCashBorrowed, maturity, blockTime);

        // Reserve fee share is restricted to less than 100
        int256 reserveFee = netTotalFee.mul(vaultConfig.reserveFeeShare).div(Constants.PERCENTAGE_DECIMALS);
        int256 nTokenFee = netTotalFee.sub(reserveFee);

        BalanceHandler.incrementFeeToReserve(vaultConfig.borrowCurrencyId, reserveFee);
        BalanceHandler.incrementVaultFeeToNToken(vaultConfig.borrowCurrencyId, nTokenFee);

        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // When a prime cash fee is accrued, the vault is "borrowing" more and then transferring the cash
            // side to the nToken and reserve.
            Emitter.emitBorrowOrRepayPrimeDebt(
                vaultConfig.vault, vaultConfig.borrowCurrencyId, netTotalFee, vaultConfig.primeRate.convertToStorageValue(netTotalFee)
            );
        }
        Emitter.emitVaultFeeTransfers(vaultConfig.vault, vaultConfig.borrowCurrencyId, nTokenFee, reserveFee);

        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.sub(netTotalFee);
    }

    /// @notice Updates the total fcash debt usage across all maturities as a single number even though
    /// they are not strictly fungible with each other, this is just used as a heuristic for the total
    /// vault risk exposure.
    /// @param vault address of vault
    /// @param currencyId relevant currency id, all vaults will borrow in a primary currency, some vaults also borrow
    /// in secondary or perhaps even tertiary currencies.
    /// @param netfCash the net amount of fCash change (borrowing < 0, lending > 0)
    function updatefCashBorrowCapacity(
        address vault,
        uint16 currencyId,
        int256 netfCash
    ) internal {
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];

        // Update the total fcash debt, when borrowing this number will increase (netfCash < 0),
        // when lending this number will decrease (netfCash > 0). 
        int256 totalfCashDebt = int256(uint256(cap.totalfCashDebt)).sub(netfCash);

        // Total fcash debt can never go negative, this would suggest that we've lent past repayment
        // of the total fCash borrowed.
        cap.totalfCashDebt = totalfCashDebt.toUint().toUint80();
        // overflow already checked above
        emit VaultBorrowCapacityChange(vault, currencyId, uint256(totalfCashDebt));
    }

    /// @notice Checks the sum of the fcash and prime cash debt usage and reverts if it is above maximum
    /// capacity. Must be called any time the total vault debt increases.
    function checkBorrowCapacity(
        address vault,
        uint16 currencyId,
        int256 totalPrimeDebtInUnderlying
    ) internal view {
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];
        int256 totalUsedBorrowCapacity = int256(uint256(cap.totalfCashDebt)).sub(totalPrimeDebtInUnderlying);
        require(totalUsedBorrowCapacity <= int256(uint256(cap.maxBorrowCapacity)), "Max Capacity");
    }

    /// @notice This will transfer borrowed asset tokens to the strategy vault and mint strategy tokens
    /// in the vault account.
    /// @param vaultConfig vault config
    /// @param account account to pass to the vault
    /// @param cashToTransferInternal amount of asset cash to  transfer in internal precision
    /// @param maturity the maturity of the vault shares
    /// the vault in enterVault
    /// @param data arbitrary data to pass to the vault
    /// @return vaultSharesMinted the amount of strategy tokens minted
    function deposit(
        VaultConfig memory vaultConfig,
        address account,
        int256 cashToTransferInternal,
        uint256 maturity,
        bytes calldata data
    ) internal returns (uint256 vaultSharesMinted) {
        // ETH transfers to the vault will be native ETH, not wrapped
        uint256 underlyingTokensTransferred = transferFromNotional(
            vaultConfig.vault, vaultConfig.borrowCurrencyId, cashToTransferInternal, vaultConfig.primeRate, false
        );
        vaultSharesMinted = IStrategyVault(vaultConfig.vault).depositFromNotional(
            account, underlyingTokensTransferred, maturity, data
        );
    }

    function depositMarginForVault(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        uint256 depositAmountExternal
    ) internal {
        (/* */, int256 primeCashMinted) = TokenHandler.depositUnderlyingExternal(
            vaultAccount.account,
            vaultConfig.borrowCurrencyId,
            depositAmountExternal.toInt(),
            vaultConfig.primeRate,
            false // excess ETH is returned natively, no excess ETH in this method
        );
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(primeCashMinted);

        // TokenHandler will emit a mint event and then the account will transfer that to the vault
        if (primeCashMinted > 0) {
            Emitter.emitTransferPrimeCash(
                vaultAccount.account, vaultConfig.vault, vaultConfig.borrowCurrencyId, primeCashMinted
            );
        }
    }

    /// @notice Redeems and transfers prime cash to the vault from Notional
    /// @param vault address that receives the token
    /// @param currencyId currency id to transfer
    /// @param cashToTransferInternal amount of prime cash to transfer
    /// @return underlyingTokensTransferred amount of underlying tokens transferred
    function transferFromNotional(
        address vault,
        uint16 currencyId,
        int256 cashToTransferInternal,
        PrimeRate memory primeRate,
        bool withdrawWrapped
    ) internal returns (uint256) {
        int256 underlyingExternalTransferred = TokenHandler.withdrawPrimeCash(
            vault,
            currencyId,
            cashToTransferInternal.neg(), // represents a withdraw
            primeRate,
            withdrawWrapped
        );

        return underlyingExternalTransferred.neg().toUint();
    }

    /// @notice Redeems without any debt repayment and sends profits back to the receiver
    function redeemWithDebtRepayment(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        address receiver,
        uint256 vaultShares,
        bytes calldata data
    ) internal returns (uint256 underlyingToReceiver) {
        uint256 amountTransferred;
        uint256 underlyingExternalToRepay;
        {
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
            // Calculates the amount of underlying tokens required to repay the debt, adjusting for potential
            // dust values.
            if (vaultAccount.tempCashBalance < 0) {
                int256 x = vaultConfig.primeRate.convertToUnderlying(vaultAccount.tempCashBalance).neg();
                underlyingExternalToRepay = underlyingToken.convertToUnderlyingExternalWithAdjustment(x).toUint();
            } else {
                // Otherwise require that cash balance is zero. Cannot have a positive cash balance in this method
                require(vaultAccount.tempCashBalance == 0);
            }

            // Repayment checks operate entirely on the underlyingExternalToRepay, the amount of
            // prime cash raised is irrelevant here since tempCashBalance is cleared to zero as
            // long as sufficient underlying has been returned to the protocol.
            (amountTransferred, underlyingToReceiver, /* primeCashRaised */) = _redeem(
                vaultConfig,
                underlyingToken,
                vaultAccount.account,
                receiver,
                vaultShares,
                vaultAccount.maturity,
                underlyingExternalToRepay,
                data
            );
        }

        if (amountTransferred < underlyingExternalToRepay) {
            // Recover any unpaid debt amount from the account directly
            uint256 residualRequired = underlyingExternalToRepay - amountTransferred;

            // actualTransferExternal is a positive number here to signify assets have entered
            // the protocol, excess ETH payments will be returned to the account
            (int256 actualTransferExternal, int256 primeCashDeposited) = TokenHandler.depositUnderlyingExternal(
                vaultAccount.account,
                vaultConfig.borrowCurrencyId,
                residualRequired.toInt(),
                vaultConfig.primeRate,
                false // excess ETH payments returned natively
            );
            amountTransferred = amountTransferred.add(actualTransferExternal.toUint());

            // Cash is held by the vault for debt repayment in this case.
            Emitter.emitTransferPrimeCash(
                vaultAccount.account, vaultConfig.vault, vaultConfig.borrowCurrencyId, primeCashDeposited
            );
        }

        // amountTransferred should never be much more than underlyingExternalToRepay (it should
        // be exactly equal) as long as the vault behaves according to spec. Any dust amounts will
        // accrue to the protocol since vaultAccount.tempCashBalance is cleared
        require(amountTransferred >= underlyingExternalToRepay, "Insufficient repayment");

        // Clear tempCashBalance to remove the dust from internal accounting. tempCashBalance must be
        // negative in this method (required at the top).
        vaultAccount.tempCashBalance = 0;
    }

    /// @notice This will call the strategy vault and have it redeem the specified amount of strategy tokens
    /// for underlying. 
    /// @return amountTransferred amount of underlying external transferred back to Notional
    /// @return underlyingToReceiver the amount of underlying that was transferred to the receiver directly
    /// from the vault. This is only used to emit events.
    /// @return primeCashRaised the amount of prime cash added to the prime cash supply on Notional (related
    /// to the amountTransferred figure)
    function _redeem(
        VaultConfig memory vaultConfig,
        Token memory underlyingToken,
        address account,
        address receiver,
        uint256 vaultShares,
        uint256 maturity,
        uint256 underlyingExternalToRepay,
        bytes calldata data
    ) private returns (
        uint256 amountTransferred,
        uint256 underlyingToReceiver,
        int256 primeCashRaised
    ) {
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
        {
            uint256 balanceBefore = underlyingToken.balanceOf(address(this));
            underlyingToReceiver = IStrategyVault(vaultConfig.vault).redeemFromNotional(
                account, receiver, vaultShares, maturity, underlyingExternalToRepay, data
            );
            uint256 balanceAfter = underlyingToken.balanceOf(address(this));
            amountTransferred = balanceAfter.sub(balanceBefore);
            TokenHandler.updateStoredTokenBalance(underlyingToken.tokenAddress, balanceBefore, balanceAfter);
        }

        // Convert to prime cash amount and update the total supply
        int256 amountInternal = underlyingToken.convertToInternal(amountTransferred.toInt());
        primeCashRaised = vaultConfig.primeRate.convertFromUnderlying(amountInternal);
        PrimeCashExchangeRate.updateTotalPrimeSupply(vaultConfig.borrowCurrencyId, primeCashRaised, amountInternal);

        _emitEvents(vaultConfig, underlyingToken, receiver, underlyingToReceiver, primeCashRaised);
    }
    
    function _emitEvents(
        VaultConfig memory vaultConfig,
        Token memory underlyingToken,
        address receiver,
        uint256 underlyingToReceiver,
        int256 primeCashRaised
    ) private {
        // Will emit:
        // MINT PRIME (vault, underlyingToReceiver + primeCashRaised)
        // TRANSFER PRIME (vault, account, underlyingToReceiver)
        // BURN PRIME (account, underlyingToReceiver)
        if (underlyingToReceiver > 0) {
            uint256 primeCashToReceiver = vaultConfig.primeRate.convertFromUnderlying(
                underlyingToken.convertToInternal(underlyingToReceiver.toInt())
            ).toUint();
            Emitter.emitVaultMintTransferBurn(
                vaultConfig.vault,
                receiver,
                vaultConfig.borrowCurrencyId,
                primeCashRaised.toUint().add(primeCashToReceiver),
                primeCashToReceiver
            );
        }
    }

    /// @notice Executes a trade on the AMM.
    /// @param currencyId id of the vault borrow currency
    /// @param maturity maturity to lend or borrow at
    /// @param netfCashToAccount positive if lending, negative if borrowing
    /// @param rateLimit 0 if there is no limit, otherwise is a slippage limit
    /// @param blockTime current time
    /// @return netPrimeCash amount of cash to credit to the account
    function executeTrade(
        uint16 currencyId,
        address vault,
        uint256 maturity,
        int256 netfCashToAccount,
        uint32 rateLimit,
        uint256 maxBorrowMarketIndex,
        uint256 blockTime
    ) internal returns (int256 netPrimeCash) {
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
        netPrimeCash = TradingAction.executeVaultTrade(currencyId, vault, trade);
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
        require(marketIndex <= maxBorrowMarketIndex); // dev: invalid maturity
        require(!isIdiosyncratic); // dev: invalid maturity
    }
}