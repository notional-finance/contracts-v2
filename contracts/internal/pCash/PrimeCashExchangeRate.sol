// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {
    PrimeCashHoldingsOracle,
    PrimeCashFactorsStorage,
    PrimeCashFactors,
    PrimeRate,
    InterestRateParameters,
    InterestRateCurveSettings,
    BalanceState,
    TotalfCashDebtStorage
} from "../../global/Types.sol";
import {FloatingPoint} from "../../math/FloatingPoint.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {Emitter} from "../Emitter.sol";
import {InterestRateCurve} from "../markets/InterestRateCurve.sol";
import {TokenHandler} from "../balances/TokenHandler.sol";
import {BalanceHandler} from "../balances/BalanceHandler.sol";

import {IPrimeCashHoldingsOracle} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";
import {IERC20} from "../../../interfaces/IERC20.sol";

library PrimeCashExchangeRate {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using InterestRateCurve for InterestRateParameters;

    event PrimeProxyDeployed(uint16 indexed currencyId, address proxy, bool isCashProxy);

    /// @notice Emits every time interest is accrued
    event PrimeCashInterestAccrued(
        uint16 indexed currencyId,
        uint256 underlyingScalar,
        uint256 supplyScalar,
        uint256 debtScalar
    );

    event PrimeCashCurveChanged(uint16 indexed currencyId);

    event PrimeCashHoldingsOracleUpdated(uint16 indexed currencyId, address oracle);

    /// @dev Reads prime cash factors from storage
    function getPrimeCashFactors(
        uint16 currencyId
    ) internal view returns (PrimeCashFactors memory p) {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        p.lastAccrueTime = s.lastAccrueTime;
        p.totalPrimeSupply = s.totalPrimeSupply;
        p.totalPrimeDebt = s.totalPrimeDebt;
        p.oracleSupplyRate = s.oracleSupplyRate;
        p.lastTotalUnderlyingValue = s.lastTotalUnderlyingValue;
        p.underlyingScalar = s.underlyingScalar;
        p.supplyScalar = s.supplyScalar;
        p.debtScalar = s.debtScalar;
        p.rateOracleTimeWindow = s.rateOracleTimeWindow5Min * 5 minutes;
    }

    function setProxyAddress(uint16 currencyId, address proxy, bool isCashProxy) internal {
        mapping(uint256 => address) storage store = isCashProxy ?
            LibStorage.getPCashAddressStorage() : LibStorage.getPDebtAddressStorage();

        // Cannot reset proxy address once set
        require(store[currencyId]== address(0)); // dev: proxy exists
        store[currencyId] = proxy;

        emit PrimeProxyDeployed(currencyId, proxy, isCashProxy);
    }

    function getCashProxyAddress(uint16 currencyId) internal view returns (address proxy) {
        proxy = LibStorage.getPCashAddressStorage()[currencyId];
    }

    function getDebtProxyAddress(uint16 currencyId) internal view returns (address proxy) {
        proxy = LibStorage.getPDebtAddressStorage()[currencyId];
    }

    function updatePrimeCashHoldingsOracle(
        uint16 currencyId,
        IPrimeCashHoldingsOracle oracle
    ) internal {
        // Set the prime cash holdings oracle first so that getTotalUnderlying will succeed
        PrimeCashHoldingsOracle storage s = LibStorage.getPrimeCashHoldingsOracle()[currencyId];
        s.oracle = oracle;

        emit PrimeCashHoldingsOracleUpdated(currencyId, address(oracle));
    }

    function getPrimeCashHoldingsOracle(uint16 currencyId) internal view returns (IPrimeCashHoldingsOracle) {
        PrimeCashHoldingsOracle storage s = LibStorage.getPrimeCashHoldingsOracle()[currencyId];
        return s.oracle;
    }

    /// @notice Returns the total value in underlying internal precision held by the
    /// Notional contract across actual underlying balances and any external money
    /// market tokens held.
    /// @dev External oracles allow:
    ///    - injection of mock oracles while testing
    ///    - adding additional protocols without having to upgrade the entire system
    ///    - reduces expensive storage reads, oracles can store the holdings information
    ///      in immutable variables which are compiled into bytecode and do not require SLOAD calls
    /// NOTE: stateful version is required for CompoundV2's accrueInterest method.
    function getTotalUnderlyingStateful(uint16 currencyId) internal returns (uint256) {
        (/* */, uint256 internalPrecision) = getPrimeCashHoldingsOracle(currencyId)
            .getTotalUnderlyingValueStateful();
        return internalPrecision;
    }

    function getTotalUnderlyingView(uint16 currencyId) internal view returns (uint256) {
        (/* */, uint256 internalPrecision) = getPrimeCashHoldingsOracle(currencyId)
            .getTotalUnderlyingValueView();
        return internalPrecision;
    }

    /// @notice Only called once during listing currencies to initialize the token balance storage. After this
    /// point the token balance storage will only be updated based on the net changes before and after deposits,
    /// withdraws, and treasury rebalancing. This is done so that donations to the protocol will not affect the
    /// valuation of prime cash.
    function initTokenBalanceStorage(uint16 currencyId, IPrimeCashHoldingsOracle oracle) internal {
        address[] memory holdings = oracle.holdings();
        address underlying = oracle.underlying();

        uint256 newBalance = currencyId == Constants.ETH_CURRENCY_ID ? 
            address(this).balance :
            IERC20(underlying).balanceOf(address(this));

        // prevBalanceOf is set to zero to ensure that this token balance has not been initialized yet
        TokenHandler.updateStoredTokenBalance(underlying, 0, newBalance);

        for (uint256 i; i < holdings.length; i++) {
            newBalance = IERC20(holdings[i]).balanceOf(address(this));
            TokenHandler.updateStoredTokenBalance(holdings[i], 0, newBalance);
        }
    }

    function initPrimeCashCurve(
        uint16 currencyId,
        uint88 totalPrimeSupply,
        InterestRateCurveSettings memory debtCurve,
        IPrimeCashHoldingsOracle oracle,
        bool allowDebt,
        uint8 rateOracleTimeWindow5Min
    ) internal {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        
        // Set the prime cash holdings oracle first so that getTotalUnderlying will succeed
        updatePrimeCashHoldingsOracle(currencyId, oracle);

        // Cannot re-initialize after the first time
        require(s.lastAccrueTime == 0);

        // Cannot initialize with zero supply balance or will be unable
        // to accrue the scalar the first time. Practically speaking, this
        // means that some dust amount of supply must be donated to the
        // reserve in order to initialize the prime cash market.
        require(0 < totalPrimeSupply);

        // Total underlying also cannot be initialized at zero or the underlying
        // scalar will be unable to accrue.
        uint256 currentTotalUnderlying = getTotalUnderlyingStateful(currencyId);
        require(0 < currentTotalUnderlying);

        s.lastAccrueTime = block.timestamp.toUint40();
        s.supplyScalar = uint80(Constants.SCALAR_PRECISION);
        s.debtScalar = uint80(Constants.SCALAR_PRECISION);
        s.totalPrimeSupply = totalPrimeSupply;
        s.allowDebt = allowDebt;
        s.rateOracleTimeWindow5Min = rateOracleTimeWindow5Min;

        s.underlyingScalar = currentTotalUnderlying
            .divInScalarPrecision(totalPrimeSupply).toUint80();
        s.lastTotalUnderlyingValue = currentTotalUnderlying.toUint88();

        // Total prime debt must be initialized at zero which implies an oracle supply
        // rate of zero (oracle supply rate here only applies to the prime cash supply).
        s.totalPrimeDebt = 0;
        s.oracleSupplyRate = 0;

        InterestRateCurve.setPrimeCashInterestRateParameters(currencyId, debtCurve);
        emit PrimeCashCurveChanged(currencyId);
    }

    function doesAllowPrimeDebt(uint16 currencyId) internal view returns (bool) {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        return s.allowDebt;
    }

    /// @notice Turns on prime cash debt. Cannot be turned off once set to true.
    function allowPrimeDebt(uint16 currencyId) internal {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.allowDebt = true;
    }

    function setRateOracleTimeWindow(uint16 currencyId, uint8 rateOracleTimeWindow5min) internal {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.rateOracleTimeWindow5Min = rateOracleTimeWindow5min;
    }

    function setMaxUnderlyingSupply(uint16 currencyId, uint256 maxUnderlyingSupply) internal returns (uint256 unpackedSupply) {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.maxUnderlyingSupply = FloatingPoint.packTo32Bits(maxUnderlyingSupply);
        unpackedSupply = FloatingPoint.unpackFromBits(uint256(s.maxUnderlyingSupply));
    }

    /// @notice Updates prime cash interest rate curve after initialization,
    /// called via governance
    function updatePrimeCashCurve(
        uint16 currencyId,
        InterestRateCurveSettings memory debtCurve
    ) internal {
        // Ensure that rates are accrued up to the current block before we change the
        // interest rate curve.
        getPrimeCashRateStateful(currencyId, block.timestamp);
        InterestRateCurve.setPrimeCashInterestRateParameters(currencyId, debtCurve);

        emit PrimeCashCurveChanged(currencyId);
    }

    /// @notice Sets the prime cash scalars on every accrual
    function _setPrimeCashFactorsOnAccrue(
        uint16 currencyId,
        uint256 primeSupplyToReserve,
        PrimeCashFactors memory p
    ) private {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        s.lastAccrueTime = p.lastAccrueTime.toUint40();
        s.underlyingScalar = p.underlyingScalar.toUint80();
        s.supplyScalar = p.supplyScalar.toUint80();
        s.debtScalar = p.debtScalar.toUint80();
        // totalPrimeSupply already includes the primeSupplyToReserve
        s.totalPrimeSupply = p.totalPrimeSupply.toUint88();
        s.totalPrimeDebt = p.totalPrimeDebt.toUint88();
        s.lastTotalUnderlyingValue = p.lastTotalUnderlyingValue.toUint88();
        s.oracleSupplyRate = p.oracleSupplyRate.toUint32();

        // Adds prime debt fees to the reserve
        if (primeSupplyToReserve > 0) {
            int256 primeSupply = primeSupplyToReserve.toInt();
            BalanceHandler.incrementFeeToReserve(currencyId, primeSupply);
            Emitter.emitMintOrBurnPrimeCash(Constants.FEE_RESERVE, currencyId, primeSupply);
        }

        emit PrimeCashInterestAccrued(
            currencyId, p.underlyingScalar, p.supplyScalar, p.debtScalar
        );
    }

    /// @notice Updates prime debt when borrowing occurs. Whenever borrowing occurs, prime
    /// supply also increases accordingly to mark that some lender in the system will now
    /// receive the accrued interest from the borrowing. This method will be called on two
    /// occasions:
    ///     - when a negative cash balance is stored outside of settlement 
    ///     - when fCash balances are settled (at the global level)
    function updateTotalPrimeDebt(
        address account,
        uint16 currencyId,
        int256 netPrimeDebtChange,
        int256 netPrimeSupplyChange
    ) internal {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        // This must always be true or we cannot update cash balances.
        require(s.lastAccrueTime == block.timestamp);

        // updateTotalPrimeDebt is only called in two scenarios:
        //  - when a negative cash balance is stored
        //  - when fCash settlement rates are set
        // Neither should be possible if allowDebt is false, fCash can only
        // be created once GovernanceAction.enableCashGroup is called and that
        // will trigger allowDebt to be set. allowDebt cannot be set to false once
        // it is set to true.
        require(s.allowDebt);

        int256 newTotalPrimeDebt = int256(uint256(s.totalPrimeDebt))
            .add(netPrimeDebtChange);
        
        // When totalPrimeDebt increases, totalPrimeSupply will also increase, no underflow
        // to zero occurs. Utilization will not exceed 100% since both values increase at the
        // same rate.

        // When totalPrimeDebt decreases, totalPrimeSupply will also decrease, but since
        // utilization is not allowed to exceed 100%, totalPrimeSupply will not go negative
        // here.
        int256 newTotalPrimeSupply = int256(uint256(s.totalPrimeSupply))
            .add(netPrimeSupplyChange);

        // PrimeRateLib#convertToStorageValue subtracts 1 from the value therefore may cause uint
        // to underflow. Clears the negative dust balance back to zero.
        if (-10 < newTotalPrimeDebt && newTotalPrimeDebt < 0) newTotalPrimeDebt = 0;
        if (-10 < newTotalPrimeSupply && newTotalPrimeSupply < 0) newTotalPrimeSupply = 0;

        s.totalPrimeDebt = newTotalPrimeDebt.toUint().toUint88();
        s.totalPrimeSupply = newTotalPrimeSupply.toUint().toUint88();

        Emitter.emitBorrowOrRepayPrimeDebt(account, currencyId, netPrimeSupplyChange, netPrimeDebtChange);
    }

    /// @notice Updates prime supply whenever tokens enter or exit the system.
    function updateTotalPrimeSupply(
        uint16 currencyId,
        int256 netPrimeSupplyChange,
        int256 netUnderlyingChange
    ) internal {
        PrimeCashFactorsStorage storage s = LibStorage.getPrimeCashFactors()[currencyId];
        // This must always be true or we cannot update cash balances.
        require(s.lastAccrueTime == block.timestamp);
        int256 newTotalPrimeSupply = int256(uint256(s.totalPrimeSupply))
            .add(netPrimeSupplyChange);
        int256 newLastTotalUnderlyingValue = int256(uint256(s.lastTotalUnderlyingValue))
            .add(netUnderlyingChange);

        // lastTotalUnderlyingValue cannot be negative since we cannot hold a negative
        // balance, if that occurs then this will revert.
        s.lastTotalUnderlyingValue = newLastTotalUnderlyingValue.toUint().toUint88();

        // On deposits, total prime supply will increase. On withdraws, total prime supply
        // will decrease. It cannot decrease below the total underlying tokens held (which
        // itself is floored at zero). If total underlying tokens held is zero, then either
        // there is no supply or the prime cash market is at 100% utilization.
        s.totalPrimeSupply = newTotalPrimeSupply.toUint().toUint88();
    }

    function getTotalfCashDebtOutstanding(
        uint16 currencyId,
        uint256 maturity
    ) internal view returns (int256) {
        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();
        return -int256(store[currencyId][maturity].totalfCashDebt);
    }

    function updateSettlementReserveForVaultsLendingAtZero(
        address vault,
        uint16 currencyId,
        uint256 maturity,
        int256 primeCashToReserve,
        int256 fCashToLend
    ) internal {
        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();
        TotalfCashDebtStorage storage s = store[currencyId][maturity];

        // Increase both figures (fCashDebt held is positive in storage)
        s.fCashDebtHeldInSettlementReserve = fCashToLend.toUint()
            .add(s.fCashDebtHeldInSettlementReserve).toUint80();
        s.primeCashHeldInSettlementReserve = primeCashToReserve.toUint()
            .add(s.primeCashHeldInSettlementReserve).toUint80();

        Emitter.emitTransferPrimeCash(vault, Constants.SETTLEMENT_RESERVE, currencyId, primeCashToReserve);
        // Minting fCash liquidity on the settlement reserve
        Emitter.emitChangefCashLiquidity(Constants.SETTLEMENT_RESERVE, currencyId, maturity, fCashToLend);
        // Positive fCash is transferred to the vault (the vault will burn it)
        Emitter.emitTransferfCash(Constants.SETTLEMENT_RESERVE, vault, currencyId, maturity, fCashToLend);
    }

    function updateTotalfCashDebtOutstanding(
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 initialfCashAmount,
        int256 finalfCashAmount
    ) internal {
        int256 netDebtChange = initialfCashAmount.negChange(finalfCashAmount);
        if (netDebtChange == 0) return;

        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();
        // No overflow due to storage size
        int256 totalDebt = -int256(store[currencyId][maturity].totalfCashDebt);
        // Total fCash Debt outstanding is negative, netDebtChange is a positive signed value
        // (i.e. netDebtChange > 0 is more debt, not less)
        int256 newTotalDebt = totalDebt.sub(netDebtChange);
        require(newTotalDebt <= 0);
        store[currencyId][maturity].totalfCashDebt = newTotalDebt.neg().toUint().toUint80();

        // Throughout the entire Notional system, negative fCash is only created when
        // when an fCash pair is minted in this method. Negative fCash is never "transferred"
        // in the system, only positive side of the fCash tokens are bought and sold.

        // When net debt changes, we emit a burn of fCash liquidity as the total debt in the
        // system has decreased.

        // When fCash debt is created (netDebtChange increases) we must mint an fCash
        // pair to ensure that total positive fCash equals total negative fCash. This
        // occurs when minting nTokens, initializing new markets, and if an account
        // transfers fCash via ERC1155 to a negative balance (effectively an OTC market
        // making operation).
        Emitter.emitChangefCashLiquidity(account, currencyId, maturity, netDebtChange);
    }

    function getPrimeInterestRates(
        uint16 currencyId,
        PrimeCashFactors memory factors
    ) internal view returns (
        uint256 annualDebtRatePreFee,
        uint256 annualDebtRatePostFee,
        uint256 annualSupplyRate
    ) {
        // Utilization is calculated in underlying terms:
        //  utilization = accruedDebtUnderlying / accruedSupplyUnderlying
        //  (totalDebt * underlyingScalar * debtScalar) / 
        //      (totalSupply * underlyingScalar * supplyScalar)
        //
        // NOTE: underlyingScalar cancels out in both numerator and denominator
        uint256 utilization;
        if (factors.totalPrimeSupply > 0) {
            // Avoid divide by zero error, supplyScalar is monotonic and initialized to 1
            utilization = factors.totalPrimeDebt.mul(factors.debtScalar)
                .divInRatePrecision(factors.totalPrimeSupply.mul(factors.supplyScalar));
        }
        InterestRateParameters memory i = InterestRateCurve.getPrimeCashInterestRateParameters(currencyId);
        
        annualDebtRatePreFee = i.getInterestRate(utilization);
        // If utilization is zero, then the annualDebtRate will be zero (as defined in the
        // interest rate curve). If we get the post fee interest rate, then the annual debt
        // rate will show some small amount and cause the debt scalar to accrue.
        if (utilization > 0) {
            // Debt rates are always "borrow" and therefore increase the interest rate
            annualDebtRatePostFee = i.getPostFeeInterestRate(annualDebtRatePreFee, true);
        }

        // Lenders receive the borrow interest accrued amortized over the total supply:
        // (annualDebtRatePreFee * totalUnderlyingDebt) / totalUnderlyingSupply,
        // this is effectively the utilization calculated above.
        if (factors.totalPrimeSupply > 0) {
            annualSupplyRate = annualDebtRatePreFee.mulInRatePrecision(utilization);
        }
    }

    /// @notice If there are fees that accrue to the reserve due to a difference in the debt rate pre fee
    /// and the debt rate post fee, calculate the amount of prime supply that goes to the reserve here.
    /// The total prime supply to the reserve is the difference in the debt scalar pre and post fee applied
    /// to the total prime debt.
    function _getScalarIncrease(
        uint16 currencyId,
        uint256 blockTime,
        PrimeCashFactors memory prior
    ) private view returns (
        uint256 debtScalarWithFee,
        uint256 newSupplyScalar,
        uint256 primeSupplyToReserve,
        uint256 annualSupplyRate
    ) {
        uint256 annualDebtRatePreFee;
        uint256 annualDebtRatePostFee;
        (annualDebtRatePreFee, annualDebtRatePostFee, annualSupplyRate) = getPrimeInterestRates(currencyId, prior);

        // Interest rates need to be scaled up to scalar precision, so we scale the time since last
        // accrue by RATE_PRECISION to save some calculations.
        // if lastAccrueTime > blockTime, will revert
        uint256 scaledTimeSinceLastAccrue = uint256(Constants.RATE_PRECISION)
            .mul(blockTime.sub(prior.lastAccrueTime));

        debtScalarWithFee = prior.debtScalar.mulInScalarPrecision(
            Constants.SCALAR_PRECISION.add(
                // No division underflow
                annualDebtRatePostFee.mul(scaledTimeSinceLastAccrue) / Constants.YEAR
            )
        );

        newSupplyScalar = prior.supplyScalar.mulInScalarPrecision(
            Constants.SCALAR_PRECISION.add(
                // No division underflow
                annualSupplyRate.mul(scaledTimeSinceLastAccrue) / Constants.YEAR
            )
        );

        // If the debt rates are the same pre and post fee, then no prime supply will be sent to the reserve.
        if (annualDebtRatePreFee == annualDebtRatePostFee) {
            return (debtScalarWithFee, newSupplyScalar, 0, annualSupplyRate);
        }

        // Calculate the increase in the debt scalar:
        // debtScalarIncrease = debtScalarWithFee - debtScalarWithoutFee
        uint256 debtScalarNoFee = prior.debtScalar.mulInScalarPrecision(
            Constants.SCALAR_PRECISION.add(
                // No division underflow
                annualDebtRatePreFee.mul(scaledTimeSinceLastAccrue) / Constants.YEAR
            )
        );
        uint256 debtScalarIncrease = debtScalarWithFee.sub(debtScalarNoFee);
        // Total prime debt paid to the reserve is:
        //  underlyingToReserve = totalPrimeDebt * debtScalarIncrease * underlyingScalar / SCALAR_PRECISION^2
        //  primeSupplyToReserve = (underlyingToReserve * SCALAR_PRECISION^2) / (supplyScalar * underlyingScalar)
        //
        //  Combining and cancelling terms results in:
        //  primeSupplyToReserve = (totalPrimeDebt * debtScalarIncrease) / supplyScalar
        primeSupplyToReserve = prior.totalPrimeDebt.mul(debtScalarIncrease).div(newSupplyScalar);
    }

    /// @notice Accrues interest to the prime cash supply scalar and debt scalar
    /// up to the current block time.
    /// @return PrimeCashFactors prime cash factors accrued up to current time
    /// @return uint256 prime supply to the reserve
    function _updatePrimeCashScalars(
        uint16 currencyId,
        PrimeCashFactors memory prior,
        uint256 currentUnderlyingValue,
        uint256 blockTime
    ) private view returns (PrimeCashFactors memory, uint256) {
        uint256 primeSupplyToReserve;
        uint256 annualSupplyRate;
        (
            prior.debtScalar,
            prior.supplyScalar,
            primeSupplyToReserve,
            annualSupplyRate
        ) = _getScalarIncrease(currencyId, blockTime, prior);

        // Prime supply is added in memory here. In getPrimeCashStateful, the actual storage values
        // will increase as well.
        prior.totalPrimeSupply = prior.totalPrimeSupply.add(primeSupplyToReserve);

        // Accrue the underlyingScalar, which represents interest earned via
        // external money market protocols.
        {
            // NOTE: this subtract reverts if this is negative. This is possible in two conditions:
            //  - the underlying value was not properly updated on the last exit
            //  - there is a misreporting in an external protocol, either due to logic error
            //    or some incident that requires a haircut to lenders
            uint256 underlyingInterestRate;

            if (prior.lastTotalUnderlyingValue > 0) {
                // If lastTotalUnderlyingValue == 0 (meaning we have no tokens held), then the
                // underlying interest rate is exactly zero and we avoid a divide by zero error.
                underlyingInterestRate = currentUnderlyingValue.sub(prior.lastTotalUnderlyingValue)
                    .divInScalarPrecision(prior.lastTotalUnderlyingValue);
            }

            prior.underlyingScalar = prior.underlyingScalar
                .mulInScalarPrecision(Constants.SCALAR_PRECISION.add(underlyingInterestRate));
            prior.lastTotalUnderlyingValue = currentUnderlyingValue;
        }

        uint256 oracleMoneyMarketRate = LibStorage.getRebalancingContext()[currencyId].oracleMoneyMarketRate;

        // Update the oracle supply rate, used for valuations of sub 3 month
        // idiosyncratic fCash
        prior.oracleSupplyRate = InterestRateCurve.updateRateOracle(
            prior.lastAccrueTime,
            // This is the annual prime supply rate plus the underlying oracle money
            // market rate.
            annualSupplyRate.add(oracleMoneyMarketRate),
            prior.oracleSupplyRate,
            prior.rateOracleTimeWindow,
            blockTime
        );

        // Update the last accrue time
        prior.lastAccrueTime = blockTime;

        return (prior, primeSupplyToReserve);
    }

    /// @notice Gets current prime cash exchange rates without setting anything
    /// in storage. Should ONLY be used for off-chain interaction.
    function getPrimeCashRateView(
        uint16 currencyId,
        uint256 blockTime
    ) internal view returns (PrimeRate memory rate, PrimeCashFactors memory factors) {
        factors = getPrimeCashFactors(currencyId);

        // Only accrue if the block time has increased
        if (factors.lastAccrueTime < blockTime) {
            uint256 currentUnderlyingValue = getTotalUnderlyingView(currencyId);
            (factors, /* primeSupplyToReserve */) = _updatePrimeCashScalars(
                currencyId, factors, currentUnderlyingValue, blockTime
            );
        } else {
            require(factors.lastAccrueTime == blockTime); // dev: revert invalid blocktime
        }

        rate = PrimeRate({
            supplyFactor: factors.supplyScalar.mul(factors.underlyingScalar).toInt(),
            debtFactor: factors.debtScalar.mul(factors.underlyingScalar).toInt(),
            oracleSupplyRate: factors.oracleSupplyRate
        });
    }

    /// @notice Gets current prime cash exchange rates and writes to storage.
    function getPrimeCashRateStateful(
        uint16 currencyId,
        uint256 blockTime
    ) internal returns (PrimeRate memory rate) {
        PrimeCashFactors memory factors = getPrimeCashFactors(currencyId);

        // Only accrue if the block time has increased
        if (factors.lastAccrueTime < blockTime) {
            uint256 primeSupplyToReserve;
            uint256 currentUnderlyingValue = getTotalUnderlyingStateful(currencyId);
            (factors, primeSupplyToReserve) = _updatePrimeCashScalars(
                currencyId, factors, currentUnderlyingValue, blockTime
            );
            _setPrimeCashFactorsOnAccrue(currencyId, primeSupplyToReserve, factors);
        } else {
            require(factors.lastAccrueTime == blockTime); // dev: revert invalid blocktime
        }

        rate = PrimeRate({
            supplyFactor: factors.supplyScalar.mul(factors.underlyingScalar).toInt(),
            debtFactor: factors.debtScalar.mul(factors.underlyingScalar).toInt(),
            oracleSupplyRate: factors.oracleSupplyRate
        });
    }
}