// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    BalanceState,
    BalanceStorage,
    SettleAmount,
    TokenType,
    AccountContext,
    PrimeRate,
    Token
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {FloatingPoint} from "../../math/FloatingPoint.sol";

import {Emitter} from "../Emitter.sol";
import {nTokenHandler} from "../nToken/nTokenHandler.sol";
import {AccountContextHandler} from "../AccountContextHandler.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";

import {TokenHandler} from "./TokenHandler.sol";
import {Incentives} from "./Incentives.sol";

library BalanceHandler {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using TokenHandler for Token;
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;

    /// @notice Emitted when a cash balance changes
    event CashBalanceChange(address indexed account, uint16 indexed currencyId, int256 netCashChange);
    /// @notice Emitted when nToken supply changes (not the same as transfers)
    event nTokenSupplyChange(address indexed account, uint16 indexed currencyId, int256 tokenSupplyChange);
    /// @notice Emitted when reserve fees are accrued
    event ReserveFeeAccrued(uint16 indexed currencyId, int256 fee);
    /// @notice Emitted when reserve balance is updated
    event ReserveBalanceUpdated(uint16 indexed currencyId, int256 newBalance);
    /// @notice Emitted when reserve balance is harvested
    event ExcessReserveBalanceHarvested(uint16 indexed currencyId, int256 harvestAmount);

    /// @notice Exists to maintain compatibility for asset token deposits that existed before
    /// prime cash. After prime cash, Notional will no longer list new asset cash tokens. Asset
    /// cash listed prior to the prime cash migration will be redeemed immediately to underlying
    /// and this method will return how much underlying that represents.
    function depositDeprecatedAssetToken(
        BalanceState memory balanceState,
        address account,
        int256 assetAmountExternal
    ) internal returns (int256 primeCashDeposited) {
        if (assetAmountExternal == 0) return 0;
        require(assetAmountExternal > 0); // dev: deposit asset token amount negative
        Token memory assetToken = TokenHandler.getDeprecatedAssetToken(balanceState.currencyId);
        require(assetToken.tokenAddress != address(0));

        // Aave tokens will not be listed prior to the prime cash migration, if NonMintable tokens
        // are minted then assetTokenTransferred is the underlying.
        if (
            assetToken.tokenType == TokenType.cToken ||
            assetToken.tokenType == TokenType.cETH
        ) {
            primeCashDeposited = assetToken.depositDeprecatedAssetToken(
                balanceState.currencyId,
                // Overflow checked above
                uint256(assetAmountExternal),
                account,
                balanceState.primeRate
            );
            balanceState.netCashChange = balanceState.netCashChange.add(primeCashDeposited);
        } else if (assetToken.tokenType == TokenType.NonMintable) {
            // In this case, no redemption is necessary and the non mintable token maps
            // 1-1 with the underlying token. Deprecated non-mintable tokens will never be ETH so
            // the returnExcessWrapped flag is set to false.
            primeCashDeposited = depositUnderlyingToken(balanceState, account, assetAmountExternal, false);
        } else {
            revert();
        }
    }

    /// @notice Marks some amount of underlying token to be transferred. Transfers will be
    /// finalized inside _finalizeTransfer unless forceTransfer is set to true
    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int256 underlyingAmountExternal,
        bool returnExcessWrapped
    ) internal returns (int256 primeCashDeposited) {
        if (underlyingAmountExternal == 0) return 0;
        require(underlyingAmountExternal > 0); // dev: deposit underlying token negative

        // Transfer the tokens and credit the balance state with the
        // amount of prime cash deposited.
        (/* actualTransfer */, primeCashDeposited) = TokenHandler.depositUnderlyingExternal(
            account,
            balanceState.currencyId,
            underlyingAmountExternal,
            balanceState.primeRate,
            returnExcessWrapped // if true, returns any excess ETH as WETH
        );
        balanceState.netCashChange = balanceState.netCashChange.add(primeCashDeposited);
        }

    /// @notice Finalize collateral liquidation, checkAllowPrimeBorrow is set to false to force
    /// a negative collateral cash balance if required.
    function finalizeCollateralLiquidation(
        BalanceState memory balanceState,
        address account,
        AccountContext memory accountContext
    ) internal {
        require(balanceState.primeCashWithdraw == 0);
        _finalize(balanceState, account, accountContext, false, false);
    }

    /// @notice Calls finalize without any withdraws. Allows the withdrawWrapped flag to be hardcoded to false.
    function finalizeNoWithdraw(
        BalanceState memory balanceState,
        address account,
        AccountContext memory accountContext
    ) internal {
        require(balanceState.primeCashWithdraw == 0);
        _finalize(balanceState, account, accountContext, false, true);
    }

    /// @notice Finalizes an account's balances with withdraws, returns the actual amount of underlying tokens transferred
    /// back to the account
    function finalizeWithWithdraw(
        BalanceState memory balanceState,
        address account,
        AccountContext memory accountContext,
        bool withdrawWrapped
    ) internal returns (int256 transferAmountExternal) {
        return _finalize(balanceState, account, accountContext, withdrawWrapped, true);
    }

    /// @notice Finalizes an account's balances, handling any transfer logic required
    /// @dev This method SHOULD NOT be used for nToken accounts, for that use setBalanceStorageForNToken
    /// as the nToken is limited in what types of balances it can hold.
    function  _finalize(
        BalanceState memory balanceState,
        address account,
        AccountContext memory accountContext,
        bool withdrawWrapped,
        bool checkAllowPrimeBorrow
    ) private returns (int256 transferAmountExternal) {
        bool mustUpdate;

        // Transfer amount is checked inside finalize transfers in case when converting to external we
        // round down to zero. This returns the actual net transfer in internal precision as well.
        transferAmountExternal = TokenHandler.withdrawPrimeCash(
            account,
            balanceState.currencyId,
            balanceState.primeCashWithdraw,
            balanceState.primeRate,
            withdrawWrapped // if true, withdraws ETH as WETH
            );

        // No changes to total cash after this point
        int256 totalCashChange = balanceState.netCashChange.add(balanceState.primeCashWithdraw);

        if (
            checkAllowPrimeBorrow &&
            totalCashChange < 0 &&
            balanceState.storedCashBalance.add(totalCashChange) < 0
        ) {
            // If the total cash change is negative and it causes the stored cash balance to become negative,
            // the account must allow prime debt. This is a safety check to ensure that accounts do not
            // accidentally borrow variable through a withdraw or a batch transaction.
            
            // Accounts can still incur negative cash during fCash settlement, that will bypass this check.
            
            // During liquidation, liquidated accounts never have negative total cash change figures except
            // in the case of negative local fCash liquidation. In that situation, setBalanceStorageForfCashLiquidation
            // will be called instead.

            // During liquidation, liquidators may have negative net cash change a token has transfer fees, however, in
            // LiquidationHelpers.finalizeLiquidatorLocal they are not allowed to go into debt.
            require(accountContext.allowPrimeBorrow, "No Prime Borrow");
        }


        if (totalCashChange != 0) {
            balanceState.storedCashBalance = balanceState.storedCashBalance.add(totalCashChange);
            mustUpdate = true;

            emit CashBalanceChange(
                account,
                uint16(balanceState.currencyId),
                totalCashChange
            );
        }

        if (balanceState.netNTokenTransfer != 0 || balanceState.netNTokenSupplyChange != 0) {
            // Final nToken balance is used to calculate the account incentive debt
            int256 finalNTokenBalance = balanceState.storedNTokenBalance
                .add(balanceState.netNTokenTransfer)
                .add(balanceState.netNTokenSupplyChange);
            // Ensure that nToken balances never become negative
            require(finalNTokenBalance >= 0, "Neg nToken");


            // overflow checked above
            Incentives.claimIncentives(balanceState, account, uint256(finalNTokenBalance));

            balanceState.storedNTokenBalance = finalNTokenBalance;

            if (balanceState.netNTokenSupplyChange != 0) {
                emit nTokenSupplyChange(
                    account,
                    uint16(balanceState.currencyId),
                    balanceState.netNTokenSupplyChange
                );
            }

            mustUpdate = true;
        }

        if (mustUpdate) {
            _setBalanceStorage(
                account,
                balanceState.currencyId,
                balanceState.storedCashBalance,
                balanceState.storedNTokenBalance,
                balanceState.lastClaimTime,
                balanceState.accountIncentiveDebt,
                balanceState.primeRate
            );
        }

        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance != 0 || balanceState.storedNTokenBalance != 0,
            Constants.ACTIVE_IN_BALANCES
        );

        if (balanceState.storedCashBalance < 0) {
            // NOTE: HAS_CASH_DEBT cannot be extinguished except by a free collateral check where all balances
            // are examined
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
        }
    }

    /**
     * @notice A special balance storage method for fCash liquidation to reduce the bytecode size.
     */
    function setBalanceStorageForfCashLiquidation(
        address account,
        AccountContext memory accountContext,
        uint16 currencyId,
        int256 netPrimeCashChange,
        PrimeRate memory primeRate
    ) internal {
        (int256 cashBalance, int256 nTokenBalance, uint256 lastClaimTime, uint256 accountIncentiveDebt) =
            getBalanceStorage(account, currencyId, primeRate);

        int256 newCashBalance = cashBalance.add(netPrimeCashChange);
        // If a cash balance is negative already we cannot put an account further into debt. In this case
        // the netCashChange must be positive so that it is coming out of debt.
        if (newCashBalance < 0) {
            require(netPrimeCashChange > 0, "Neg Cash");
            // NOTE: HAS_CASH_DEBT cannot be extinguished except by a free collateral check
            // where all balances are examined. In this case the has cash debt flag should
            // already be set (cash balances cannot get more negative) but we do it again
            // here just to be safe.
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
        }

        bool isActive = newCashBalance != 0 || nTokenBalance != 0;
        accountContext.setActiveCurrency(currencyId, isActive, Constants.ACTIVE_IN_BALANCES);

        // Emit the event here, we do not call finalize
        emit CashBalanceChange(account, currencyId, netPrimeCashChange);

        _setBalanceStorage(
            account,
            currencyId,
            newCashBalance,
            nTokenBalance,
            lastClaimTime,
            accountIncentiveDebt,
            primeRate
        );
    }

    /// @notice Helper method for settling the output of the SettleAssets method
    function finalizeSettleAmounts(
        address account,
        AccountContext memory accountContext,
        SettleAmount[] memory settleAmounts
    ) internal {
        for (uint256 i = 0; i < settleAmounts.length; i++) {
            SettleAmount memory amt = settleAmounts[i];
            if (amt.netCashChange == 0) continue;

            (
                int256 cashBalance,
                int256 nTokenBalance,
                uint256 lastClaimTime,
                uint256 accountIncentiveDebt
            ) = getBalanceStorage(account, amt.currencyId);

            cashBalance = cashBalance.add(amt.netCashChange);
            accountContext.setActiveCurrency(
                amt.currencyId,
                cashBalance != 0 || nTokenBalance != 0,
                Constants.ACTIVE_IN_BALANCES
            );

            if (cashBalance < 0) {
                accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
            }

            emit CashBalanceChange(
                account,
                uint16(amt.currencyId),
                amt.netCashChange
            );

            _setBalanceStorage(
                account,
                amt.currencyId,
                cashBalance,
                nTokenBalance,
                lastClaimTime,
                accountIncentiveDebt
            );
        }
    }

    /// @notice Special method for setting balance storage for nToken
    function setBalanceStorageForNToken(
        address nTokenAddress,
        uint16 currencyId,
        int256 cashBalance
    ) internal {
        _setPositiveCashBalance(nTokenAddress, currencyId, cashBalance);
    }

    /// @notice Asses a fee or a refund to the nToken for leveraged vaults
    function incrementVaultFeeToNToken(uint16 currencyId, int256 fee) internal {
        require(fee >= 0); // dev: invalid fee
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        int256 cashBalance = getPositiveCashBalance(nTokenAddress, currencyId);
        cashBalance = cashBalance.add(fee);
        _setPositiveCashBalance(nTokenAddress, currencyId, cashBalance);
    }

    /// @notice increments fees to the reserve
    function incrementFeeToReserve(uint16 currencyId, int256 fee) internal {
        require(fee >= 0); // dev: invalid fee
        // prettier-ignore
        int256 totalReserve = getPositiveCashBalance(Constants.FEE_RESERVE, currencyId);
        totalReserve = totalReserve.add(fee);
        _setPositiveCashBalance(Constants.FEE_RESERVE, currencyId, totalReserve);
        emit ReserveFeeAccrued(uint16(currencyId), fee);
    }

    /// @notice harvests excess reserve balance
    function harvestExcessReserveBalance(uint16 currencyId, int256 reserve, int256 assetInternalRedeemAmount) internal {
        // parameters are validated by the caller
        reserve = reserve.subNoNeg(assetInternalRedeemAmount);
        _setPositiveCashBalance(Constants.FEE_RESERVE, currencyId, reserve);
        emit ExcessReserveBalanceHarvested(currencyId, assetInternalRedeemAmount);
    }

    /// @notice sets the reserve balance, see TreasuryAction.setReserveCashBalance
    function setReserveCashBalance(uint16 currencyId, int256 newBalance) internal {
        require(newBalance >= 0); // dev: invalid balance
        _setPositiveCashBalance(Constants.FEE_RESERVE, currencyId, newBalance);
        emit ReserveBalanceUpdated(currencyId, newBalance);
    }

    function getPositiveCashBalance(
        address account,
        uint16 currencyId
    ) internal view returns (int256 cashBalance) {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];
        cashBalance = balanceStorage.cashBalance;
        // Positive cash balances do not require prime rate conversion
        require(cashBalance >= 0);
    }

    /// @notice Sets cash balances for special system accounts that can only ever have positive
    /// cash balances (and nothing else). Because positive prime cash balances do not require any
    /// adjustments this does not require a PrimeRate object
    function _setPositiveCashBalance(address account, uint16 currencyId, int256 newCashBalance) internal {
        require(newCashBalance >= 0); // dev: invalid balance
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];
        balanceStorage.cashBalance = newCashBalance.toInt88();
    }

    /// @notice Sets internal balance storage.
    function _setBalanceStorage(
        address account,
        uint16 currencyId,
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 accountIncentiveDebt,
        PrimeRate memory pr
    ) internal {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        if (lastClaimTime == 0) {
            // In this case the account has migrated and we set the accountIncentiveDebt
            // The maximum NOTE supply is 100_000_000e8 (1e16) which is less than 2^56 (7.2e16) so we should never
            // encounter an overflow for accountIncentiveDebt
            require(accountIncentiveDebt <= type(uint56).max); // dev: account incentive debt overflow
            balanceStorage.accountIncentiveDebt = uint56(accountIncentiveDebt);
        } else {
            // In this case the last claim time has not changed and we do not update the last integral supply
            // (stored in the accountIncentiveDebt position)
            require(lastClaimTime == balanceStorage.lastClaimTime);
        }

        balanceStorage.lastClaimTime = lastClaimTime.toUint32();
        balanceStorage.nTokenBalance = nTokenBalance.toUint().toUint80();

        balanceStorage.cashBalance = pr.convertToStorageNonSettlementNonVault(
            account,
            currencyId,
            balanceStorage.cashBalance, // previous stored value
            cashBalance // signed cash balance
        ).toInt88();
    }

    /// @notice Gets internal balance storage, nTokens are stored alongside cash balances
    function getBalanceStorage(
        address account,
        uint16 currencyId,
        PrimeRate memory pr
    ) internal view returns (
            int256 cashBalance,
            int256 nTokenBalance,
            uint256 lastClaimTime,
            uint256 accountIncentiveDebt
    ) {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        nTokenBalance = balanceStorage.nTokenBalance;
        lastClaimTime = balanceStorage.lastClaimTime;
        if (lastClaimTime > 0) {
            // NOTE: this is only necessary to support the deprecated integral supply values, which are stored
            // in the accountIncentiveDebt slot
            accountIncentiveDebt = FloatingPoint.unpackFromBits(balanceStorage.accountIncentiveDebt);
        } else {
            accountIncentiveDebt = balanceStorage.accountIncentiveDebt;
        }

        cashBalance = pr.convertFromStorage(balanceStorage.cashBalance);
    }

    /// @notice Loads a balance state memory object
    /// @dev Balance state objects occupy a lot of memory slots, so this method allows
    /// us to reuse them if possible
    function _loadBalanceState(
        BalanceState memory balanceState,
        address account,
        uint16 currencyId,
        AccountContext memory accountContext
    ) private view {
        require(0 < currencyId && currencyId <= Constants.MAX_CURRENCIES); // dev: invalid currency id
        balanceState.currencyId = currencyId;

        if (accountContext.isActiveInBalances(currencyId)) {
            (
                balanceState.storedCashBalance,
                balanceState.storedNTokenBalance,
                balanceState.lastClaimTime,
                balanceState.accountIncentiveDebt
            ) = getBalanceStorage(account, currencyId, balanceState.primeRate);
        } else {
            balanceState.storedCashBalance = 0;
            balanceState.storedNTokenBalance = 0;
            balanceState.lastClaimTime = 0;
            balanceState.accountIncentiveDebt = 0;
        }

        balanceState.netCashChange = 0;
        balanceState.primeCashWithdraw = 0;
        balanceState.netNTokenTransfer = 0;
        balanceState.netNTokenSupplyChange = 0;
    }

    /// @notice Used when manually claiming incentives in nTokenAction. Also sets the balance state
    /// to storage to update the accountIncentiveDebt. lastClaimTime will be set to zero as accounts
    /// are migrated to the new incentive calculation
    function claimIncentivesManual(BalanceState memory balanceState, address account)
        internal
        returns (uint256 incentivesClaimed)
    {
        incentivesClaimed = Incentives.claimIncentives(
            balanceState,
            account,
            balanceState.storedNTokenBalance.toUint()
        );

        _setBalanceStorage(
            account,
            balanceState.currencyId,
            balanceState.storedCashBalance,
            balanceState.storedNTokenBalance,
            balanceState.lastClaimTime,
            balanceState.accountIncentiveDebt,
            balanceState.primeRate
        );
    }

    function loadBalanceState(
        BalanceState memory balanceState,
        address account,
        uint16 currencyId,
        AccountContext memory accountContext
    ) internal {
        balanceState.primeRate = PrimeRateLib.buildPrimeRateStateful(currencyId);
        _loadBalanceState(balanceState, account, currencyId, accountContext);
    }

    function loadBalanceStateView(
        BalanceState memory balanceState,
        address account,
        uint16 currencyId,
        AccountContext memory accountContext
    ) internal view {
        (balanceState.primeRate, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);
        _loadBalanceState(balanceState, account, currencyId, accountContext);
    }

    function getBalanceStorageView(
        address account,
        uint16 currencyId,
        uint256 blockTime
    ) internal view returns (
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 accountIncentiveDebt
    ) {
        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
        return getBalanceStorage(account, currencyId, pr);
    }

}
