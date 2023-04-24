// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    PrimeCashFactors,
    PrimeCashFactorsStorage,
    PrimeSettlementRateStorage,
    MarketParameters,
    TotalfCashDebtStorage
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {Deployments} from "../../global/Deployments.sol";

import {FloatingPoint} from "../../math/FloatingPoint.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {Emitter} from "../Emitter.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";
import {nTokenHandler} from "../nToken/nTokenHandler.sol";
import {PrimeCashExchangeRate} from "./PrimeCashExchangeRate.sol";
import {Market} from "../markets/Market.sol";

library PrimeRateLib {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using Market for MarketParameters;

    /// @notice Emitted when a settlement rate is set
    event SetPrimeSettlementRate(
        uint256 indexed currencyId,
        uint256 indexed maturity,
        int256 supplyFactor,
        int256 debtFactor
    );

    /// Prime cash balances are stored differently than they are used on the stack
    /// and in memory. On the stack, all prime cash balances (positive and negative) are fungible
    /// with each other and denominated in prime cash supply terms. In storage, negative prime cash
    /// (i.e. prime cash debt) is is stored in different terms so that it can properly accrue interest
    /// over time. In other words, positive prime cash balances are static (non-rebasing), but negative
    /// prime cash balances are monotonically increasing (i.e. rebasing) over time. This is because a
    /// negative prime cash balance represents an ever increasing amount of positive prime cash owed.
    ///
    /// Math is as follows:
    ///   positivePrimeSupply * supplyFactor = underlying
    ///   negativePrimeDebt * debtFactor = underlying
    ///
    /// Setting them equal:
    ///   positivePrimeSupply * supplyFactor = negativePrimeDebt * debtFactor
    ///
    ///   positivePrimeSupply = (negativePrimeDebt * debtFactor) / supplyFactor
    ///   negativePrimeDebt = (positivePrimeSupply * supplyFactor) / debtFactor
    
    /// @notice Converts stored cash balance into a signed value in prime supply
    /// terms (see comment above)
    function convertFromStorage(
        PrimeRate memory pr,
        int256 storedCashBalance
    ) internal pure returns (int256 signedPrimeSupplyValue) {
        if (storedCashBalance >= 0) {
            return storedCashBalance;
        } else {
            // Convert negative stored cash balance to signed prime supply value
            // signedPrimeSupply = (negativePrimeDebt * debtFactor) / supplyFactor

            // cashBalance is stored as int88, debt factor is uint80 * uint80 so there
            // is no chance of phantom overflow (88 + 80 + 80 = 248) on mul
            return storedCashBalance.mul(pr.debtFactor).div(pr.supplyFactor);
        }
    }

    function convertSettledfCashView(
        PrimeRate memory presentPrimeRate,
        uint16 currencyId,
        uint256 maturity,
        int256 fCashBalance,
        uint256 blockTime
    ) internal view returns (int256 signedPrimeSupplyValue) {
        PrimeRate memory settledPrimeRate = buildPrimeRateSettlementView(currencyId, maturity, blockTime);
        (signedPrimeSupplyValue, /* */) = _convertSettledfCash(presentPrimeRate, settledPrimeRate, fCashBalance);
    }

    function convertSettledfCashInVault(
        uint16 currencyId,
        uint256 maturity,
        int256 fCashBalance,
        address vault
    ) internal returns (int256 settledPrimeStorageValue) {
        (PrimeRate memory settledPrimeRate, bool isSet) = _getPrimeSettlementRate(currencyId, maturity);
        // Requires that the vault has a settlement rate set first. This means that markets have been
        // initialized already. Vaults cannot have idiosyncratic borrow dates so relying on market initialization
        // is safe.
        require(isSet); // dev: settlement rate unset

        // This is exactly how much prime debt the vault owes at settlement.
        settledPrimeStorageValue = convertUnderlyingToDebtStorage(settledPrimeRate, fCashBalance);

        // Only emit the settle fcash event for the vault, not individual accounts
        if (vault != address(0)) {
            Emitter.emitSettlefCash(
                vault, currencyId, maturity, fCashBalance, settledPrimeStorageValue
            );
        }
    }

    /// @notice Converts settled fCash to the current signed prime supply value
    function convertSettledfCash(
        PrimeRate memory presentPrimeRate,
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 fCashBalance,
        uint256 blockTime
    ) internal returns (int256 signedPrimeSupplyValue) {
        PrimeRate memory settledPrimeRate = buildPrimeRateSettlementStateful(currencyId, maturity, blockTime);

        int256 settledPrimeStorageValue;
        (signedPrimeSupplyValue, settledPrimeStorageValue) = _convertSettledfCash(
            presentPrimeRate, settledPrimeRate, fCashBalance
        );

        // Allows vault accounts to suppress this event because it is not relevant to them
        if (account != address(0)) {
            Emitter.emitSettlefCash(
                account, currencyId, maturity, fCashBalance, settledPrimeStorageValue
            );
        }
    }

    /// @notice Converts an fCash balance to a signed prime supply value.
    /// @return signedPrimeSupplyValue the current (signed) prime cash value of the fCash 
    /// @return settledPrimeStorageValue the storage value of the fCash at settlement, used for
    /// emitting events only
    function _convertSettledfCash(
        PrimeRate memory presentPrimeRate,
        PrimeRate memory settledPrimeRate,
        int256 fCashBalance
    ) private pure returns (int256 signedPrimeSupplyValue, int256 settledPrimeStorageValue) {
        // These values are valid at the time of settlement.
        signedPrimeSupplyValue = convertFromUnderlying(settledPrimeRate, fCashBalance);
        settledPrimeStorageValue = convertToStorageValue(settledPrimeRate, signedPrimeSupplyValue);

        // If the signed prime supply value is negative, we need to accrue interest on the
        // debt up to the present from the settled prime rate. This simulates storing the
        // the debt, reading the debt from storage and then accruing interest up to the
        // current time. This is only required for debt values.
        // debtSharesAtSettlement = signedPrimeSupplyValue * settled.supplyFactor / settled.debtFactor
        // currentSignedPrimeSupplyValue = debtSharesAtSettlement * present.debtFactor / present.supplyFactor
        if (signedPrimeSupplyValue < 0) {
            // Divide between multiplication actions to protect against a phantom overflow at 256 due
            // to the two mul in the numerator.
            signedPrimeSupplyValue = signedPrimeSupplyValue
                .mul(settledPrimeRate.supplyFactor)
                .div(settledPrimeRate.debtFactor)
                .mul(presentPrimeRate.debtFactor)
                .div(presentPrimeRate.supplyFactor)
                // subtract one to protect protocol against rounding errors in division operations
                .sub(1);
        }
    }

    function convertToStorageValue(
        PrimeRate memory pr,
        int256 signedPrimeSupplyValueToStore
    ) internal pure returns (int256 newStoredCashBalance) {
        newStoredCashBalance = signedPrimeSupplyValueToStore >= 0 ?
            signedPrimeSupplyValueToStore :
            // negativePrimeDebt = (signedPrimeSupply * supplyFactor) / debtFactor
            // subtract one to increase debt and protect protocol against rounding errors
            signedPrimeSupplyValueToStore.mul(pr.supplyFactor).div(pr.debtFactor).sub(1);
    }

    /// @notice Updates total prime debt during settlement if debts are repaid by cash
    /// balances.
    /// @param pr current prime rate
    /// @param currencyId currency id this prime rate refers to
    /// @param previousSignedCashBalance the previous signed supply value of the stored cash balance
    /// @param positiveSettledCash amount of positive cash balances that have settled
    /// @param negativeSettledCash amount of negative cash balances that have settled
    function convertToStorageInSettlement(
        PrimeRate memory pr,
        address account,
        uint16 currencyId,
        int256 previousSignedCashBalance,
        int256 positiveSettledCash,
        int256 negativeSettledCash
    ) internal returns (int256 newStoredCashBalance) {
        // The new cash balance is the sum of all the balances converted to a proper storage value
        int256 endSignedBalance = previousSignedCashBalance.add(positiveSettledCash).add(negativeSettledCash);
        newStoredCashBalance = convertToStorageValue(pr, endSignedBalance);

        // At settlement, the total prime debt outstanding is increased by the total fCash debt
        // outstanding figure in `_settleTotalfCashDebts`. This figure, however, is not aware of
        // individual accounts that have sufficient cash (or matured fCash) to repay a settled debt.
        // An example of the scenario would be an account with:
        //      +100 units of ETH cash balance, -50 units of matured fETH
        //
        // At settlement the total ETH debt outstanding is set to -50 ETH, causing an increase in
        // prime cash utilization and an increase to the prime cash debt rate. If this account settled
        // exactly at maturity, they would have +50 units of ETH cash balance and have accrued zero
        // additional variable rate debt. However, since the the smart contract is not made aware of this
        // without an explicit settlement transaction, it will continue to accrue interest to prime cash
        // suppliers (meaning that this account is paying variable interest on its -50 units of matured
        // fETH until it actually issues a settlement transaction).
        //
        // The effect of this is that the account will be paying the spread between the prime cash supply
        // interest rate and the prime debt interest rate for the period where it is not settled. If the
        // account remains un-settled for long enough, it will slowly creep into insolvency (i.e. once the
        // debt is greater than the cash, the account is insolvent). However, settlement transactions are
        // permission-less and only require the payment of a minor gas cost so anyone can settle an account
        // to stop the accrual of the variable rate debt and prevent an insolvency.
        //
        // The variable debt accrued by this account up to present time must be paid and is calculated
        // in `_convertSettledfCash`. The logic below will detect the netPrimeDebtChange based on the
        // cash balances and settled amounts and properly update the total prime debt figure accordingly.

        // Only need to update total prime debt when there is a debt repayment via existing cash balances
        // or positive settled cash. In all other cases, settled prime debt or existing prime debt are
        // already captured by the total prime debt figure.
        require(0 <= positiveSettledCash);
        require(negativeSettledCash <= 0);

        if (0 < previousSignedCashBalance) {
            positiveSettledCash = previousSignedCashBalance.add(positiveSettledCash);
        } else {
            negativeSettledCash = previousSignedCashBalance.add(negativeSettledCash);
        }

        int256 netPrimeSupplyChange;
        if (negativeSettledCash.neg() < positiveSettledCash) {
            // All of the negative settled cash is repaid
            netPrimeSupplyChange = negativeSettledCash;
        } else {
            // Positive cash portion of the debt is repaid
            netPrimeSupplyChange = positiveSettledCash.neg();
        }

        // netPrimeSupplyChange should always be negative or zero at this point
        if (netPrimeSupplyChange < 0) {
            int256 netPrimeDebtChange = netPrimeSupplyChange.mul(pr.supplyFactor).div(pr.debtFactor);

            PrimeCashExchangeRate.updateTotalPrimeDebt(
                account,
                currencyId,
                netPrimeDebtChange,
                netPrimeSupplyChange
            );
        }
    }

    /// @notice Converts signed prime supply value into a stored prime cash balance
    /// value, converting negative prime supply values into prime debt values if required.
    /// Also, updates totalPrimeDebt based on the net change in storage values. Should not
    /// be called during settlement.
    function convertToStorageNonSettlementNonVault(
        PrimeRate memory pr,
        address account,
        uint16 currencyId,
        int256 previousStoredCashBalance,
        int256 signedPrimeSupplyValueToStore
    ) internal returns (int256 newStoredCashBalance) {
        newStoredCashBalance = convertToStorageValue(pr, signedPrimeSupplyValueToStore);
        updateTotalPrimeDebt(
            pr,
            account,
            currencyId,
            // This will return 0 if both cash balances are positive.
            previousStoredCashBalance.negChange(newStoredCashBalance)
        );
    }

    /// @notice Updates totalPrimeDebt given the change to the stored cash balance
    function updateTotalPrimeDebt(
        PrimeRate memory pr,
        address account,
        uint16 currencyId,
        int256 netPrimeDebtChange
    ) internal {
        if (netPrimeDebtChange != 0) {
            // Whenever prime debt changes, prime supply must also change to the same degree in
            // its own denomination. This marks the position of some lender in the system who
            // will receive the repayment of the debt change.
            // NOTE: total prime supply will also change when tokens enter or exit the system.
            int256 netPrimeSupplyChange = netPrimeDebtChange.mul(pr.debtFactor).div(pr.supplyFactor);

            PrimeCashExchangeRate.updateTotalPrimeDebt(
                account,
                currencyId,
                netPrimeDebtChange,
                netPrimeSupplyChange
            );
        }
    }

    /// @notice Converts a prime cash balance to underlying (both in internal 8
    /// decimal precision).
    function convertToUnderlying(
        PrimeRate memory pr,
        int256 primeCashBalance
    ) internal pure returns (int256) {
        return primeCashBalance.mul(pr.supplyFactor).div(Constants.DOUBLE_SCALAR_PRECISION);
    }

    /// @notice Converts underlying to a prime cash balance (both in internal 8
    /// decimal precision).
    function convertFromUnderlying(
        PrimeRate memory pr,
        int256 underlyingBalance
    ) internal pure returns (int256) {
        return underlyingBalance.mul(Constants.DOUBLE_SCALAR_PRECISION).div(pr.supplyFactor);
    }

    function convertDebtStorageToUnderlying(
        PrimeRate memory pr,
        int256 debtStorage
    ) internal pure returns (int256) {
        // debtStorage must be negative
        require(debtStorage < 1);
        if (debtStorage == 0) return 0;

        return debtStorage.mul(pr.debtFactor).div(Constants.DOUBLE_SCALAR_PRECISION).sub(1);
    }

    function convertUnderlyingToDebtStorage(
        PrimeRate memory pr,
        int256 underlying
    ) internal pure returns (int256) {
        // Floor dust balances at zero to prevent the following require check from reverting
        if (0 <= underlying && underlying < 10) return 0;
        require(underlying < 0);
        // underlying debt is specified as a negative number and therefore subtract
        // one to protect the protocol against rounding errors
        return underlying.mul(Constants.DOUBLE_SCALAR_PRECISION).div(pr.debtFactor).sub(1);
    }
    
    /// @notice Returns a prime rate object accrued up to the current time and updates
    /// values in storage.
    function buildPrimeRateStateful(
        uint16 currencyId
    ) internal returns (PrimeRate memory) {
        return PrimeCashExchangeRate.getPrimeCashRateStateful(currencyId, block.timestamp);
    }

    /// @notice Returns a prime rate object for settlement at a particular maturity
    function buildPrimeRateSettlementView(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) internal view returns (PrimeRate memory pr) {
        bool isSet;
        (pr, isSet) = _getPrimeSettlementRate(currencyId, maturity);
        
        if (!isSet) {
            // Return the current cash rate if settlement rate not found
            (pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
        }
    }

    /// @notice Returns a prime rate object for settlement at a particular maturity,
    /// and sets both accrued values and the settlement rate (if not set already).
    function buildPrimeRateSettlementStateful(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) internal returns (PrimeRate memory pr) {
        bool isSet;
        (pr, isSet) = _getPrimeSettlementRate(currencyId, maturity);

        if (!isSet) {
            pr = _setPrimeSettlementRate(currencyId, maturity, blockTime);
        }
    }

    /// @notice Loads the settlement rate from storage or uses the current rate if it
    /// has not yet been set.
    function _getPrimeSettlementRate(
        uint16 currencyId,
        uint256 maturity
    ) private view returns (PrimeRate memory pr, bool isSet) {
        mapping(uint256 => mapping(uint256 =>
            PrimeSettlementRateStorage)) storage store = LibStorage.getPrimeSettlementRates();
        PrimeSettlementRateStorage storage rateStorage = store[currencyId][maturity];
        isSet = rateStorage.isSet;

        // If the settlement rate is not set, then this method will return zeros
        if (isSet) {
            uint256 underlyingScalar = rateStorage.underlyingScalar;
            pr.supplyFactor = int256(uint256(rateStorage.supplyScalar).mul(underlyingScalar));
            pr.debtFactor = int256(uint256(rateStorage.debtScalar).mul(underlyingScalar));
        }
    }

    function _setPrimeSettlementRate(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) private returns (PrimeRate memory pr) {
        // Accrues prime rates up to current time and sets them
        pr = PrimeCashExchangeRate.getPrimeCashRateStateful(currencyId, blockTime);
        // These are the accrued factors
        PrimeCashFactors memory factors = PrimeCashExchangeRate.getPrimeCashFactors(currencyId);

        mapping(uint256 => mapping(uint256 =>
            PrimeSettlementRateStorage)) storage store = LibStorage.getPrimeSettlementRates();
        PrimeSettlementRateStorage storage rateStorage = store[currencyId][maturity];

        require(Deployments.NOTIONAL_V2_FINAL_SETTLEMENT < maturity); // dev: final settlement
        require(factors.lastAccrueTime == blockTime); // dev: did not accrue
        require(0 < blockTime); // dev: zero block time
        require(maturity <= blockTime); // dev: settlement rate timestamp
        require(0 < pr.supplyFactor); // dev: settlement rate zero
        require(0 < pr.debtFactor); // dev: settlement rate zero

        rateStorage.underlyingScalar = factors.underlyingScalar.toUint80();
        rateStorage.supplyScalar = factors.supplyScalar.toUint80();
        rateStorage.debtScalar = factors.debtScalar.toUint80();
        rateStorage.isSet = true;

        _settleTotalfCashDebts(currencyId, maturity, pr);

        emit SetPrimeSettlementRate(
            currencyId,
            maturity,
            pr.supplyFactor,
            pr.debtFactor
        );
    }

    function _settleTotalfCashDebts(
        uint16 currencyId,
        uint256 maturity,
        PrimeRate memory settlementRate
    ) private {
        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();
        TotalfCashDebtStorage storage s = store[currencyId][maturity];
        int256 totalDebt = -int256(s.totalfCashDebt);
        
        // The nToken must be settled first via InitializeMarkets if there is any liquidity
        // in the matching market (if one exists).
        MarketParameters memory market;
        market.loadSettlementMarket(currencyId, maturity, maturity);
        require(market.totalLiquidity == 0, "Must init markets");

        // totalDebt is negative, but netPrimeSupplyChange and netPrimeDebtChange must both be positive
        // since we are increasing the total debt load.
        int256 netPrimeSupplyChange = convertFromUnderlying(settlementRate, totalDebt.neg());
        int256 netPrimeDebtChange = convertUnderlyingToDebtStorage(settlementRate, totalDebt).neg();

        // The settlement reserve will receive all of the prime debt initially and each account
        // will receive prime cash or prime debt as they settle individually.
        PrimeCashExchangeRate.updateTotalPrimeDebt(
            Constants.SETTLEMENT_RESERVE, currencyId, netPrimeDebtChange, netPrimeSupplyChange
        );

        // This is purely done to fully reconcile off chain accounting with the edge condition where
        // leveraged vaults lend at zero interest.
        int256 fCashDebtInReserve = -int256(s.fCashDebtHeldInSettlementReserve);
        int256 primeCashInReserve = int256(s.primeCashHeldInSettlementReserve);
        if (fCashDebtInReserve > 0 || primeCashInReserve > 0) {
            int256 settledPrimeCash = convertFromUnderlying(settlementRate, fCashDebtInReserve);
            int256 excessCash;
            if (primeCashInReserve > settledPrimeCash) {
                excessCash = primeCashInReserve - settledPrimeCash;
                BalanceHandler.incrementFeeToReserve(currencyId, excessCash);
            } 

            Emitter.emitSettlefCashDebtInReserve(
                currencyId, maturity, fCashDebtInReserve, settledPrimeCash, excessCash
            );
        }

        // Clear the storage slot, no longer needed
        delete store[currencyId][maturity];
    }

    /// @notice Checks whether or not a currency has exceeded its total prime supply cap. Used to
    /// prevent some listed currencies to be used as collateral above a threshold where liquidations
    /// can be safely done on chain.
    /// @dev Called during deposits in AccountAction and BatchAction. Supply caps are not checked
    /// during settlement, liquidation and withdraws.
    function checkSupplyCap(PrimeRate memory pr, uint16 currencyId) internal view {
        (uint256 maxUnderlyingSupply, uint256 totalUnderlyingSupply) = getSupplyCap(pr, currencyId);
        if (maxUnderlyingSupply == 0) return;

        require(totalUnderlyingSupply <= maxUnderlyingSupply, "Over Supply Cap");
    }

    function getSupplyCap(
        PrimeRate memory pr,
        uint16 currencyId
    ) internal view returns (uint256 maxUnderlyingSupply, uint256 totalUnderlyingSupply) {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        maxUnderlyingSupply = FloatingPoint.unpackFromBits(s.maxUnderlyingSupply);
        // No potential for overflow due to storage size
        int256 totalPrimeSupply = int256(uint256(s.totalPrimeSupply));
        totalUnderlyingSupply = convertToUnderlying(pr, totalPrimeSupply).toUint();
    }
}