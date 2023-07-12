import math

import brownie
import pytest
from brownie import Contract
import eth_abi
from brownie.convert.datatypes import Wei, HexString
from brownie.network import Chain, Rpc
from brownie.test import given, strategy
from tests.constants import FEE_RESERVE, RATE_PRECISION, SECONDS_IN_DAY, SECONDS_IN_QUARTER, SECONDS_IN_YEAR, ZERO_ADDRESS
from tests.helpers import get_interest_rate_curve, get_market_state, get_tref, simulate_init_markets

chain = Chain()


class TestPrimeCash:
    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @pytest.fixture(scope="module", autouse=True)
    def mock(self, MockPrimeCash, MockSettingsLib, accounts):
        settingsLib = MockSettingsLib.deploy({"from": accounts[0]})
        mock = MockPrimeCash.deploy(settingsLib, {"from": accounts[0]})
        # 100_000e18 ETH
        Rpc().backend._request(
            "evm_setAccountBalance", [mock.address, "0x00000000000000000000000000000000000000000000152d02c7e14af6800000"]
        )

        return Contract.from_abi("mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0])

    @pytest.fixture(scope="module", autouse=True)
    def oracle(self, UnderlyingHoldingsOracle, mock, accounts):
        o = UnderlyingHoldingsOracle.deploy(mock.address, ZERO_ADDRESS, {"from": accounts[0]})
        return o

    def get_debt_amount(self, initSupply, utilization):
        return math.floor(initSupply * (utilization / (RATE_PRECISION - utilization)))

    def test_init_prime_cash_curve(self, mock, oracle):
        # Cannot update before initialization
        with brownie.reverts():
            mock.updatePrimeCashCurve(1, get_interest_rate_curve())

        txn = mock.initPrimeCashCurve(1, 100e8, 10e8, get_interest_rate_curve(), oracle, True)

        # Cannot initialize twice
        with brownie.reverts():
            mock.initPrimeCashCurve(1, 100e8, 10e8, get_interest_rate_curve(), oracle, True)

        factors = mock.getPrimeCashFactors(1)

        assert factors["lastAccrueTime"] == txn.timestamp
        assert factors["totalPrimeSupply"] == 110e8
        assert factors["totalPrimeDebt"] == 10e8
        assert txn.events["PrimeCashCurveChanged"]

    def test_balance_change_reverts_on_negative(self, mock, oracle):
        mock.initPrimeCashCurve(1, 200_000e8, 100_000e8, get_interest_rate_curve(), oracle, True)
        
        # Total Prime Supply = 300_000e8, Total Prime Debt = 100_000e8
        with brownie.reverts():
            mock.updateTotalPrimeDebt(1, -50_000e8, -301_000e8)

        with brownie.reverts():
            mock.updateTotalPrimeDebt(1, -101_000e8, -199_000e8)

        with brownie.reverts():
            mock.updateTotalPrimeSupply(1, -101_000e8, -101_000e8)

        with brownie.reverts():
            mock.updateTotalPrimeSupply(1, -301_000e8, -99_000e8)

    def test_no_accrue_at_same_block(self, mock, oracle):
        txn = mock.initPrimeCashCurve(
            1, 200_000e8, 100_000e8, get_interest_rate_curve(), oracle, True
        )

        prNoAccrue = mock.buildPrimeRateStateful(1, txn.timestamp)
        assert "PrimeCashInterestAccrued" not in prNoAccrue.events

    def test_revert_if_block_time_decreases(self, mock, oracle):
        txn = mock.initPrimeCashCurve(
            1, 200_000e8, 100_000e8, get_interest_rate_curve(), oracle, True
        )

        with brownie.reverts():
            mock.buildPrimeRateStateful(1, txn.timestamp - 1)

    def test_no_reverts_at_zero_supply(self, mock, oracle):
        mock.initPrimeCashCurve(1, 100_000e8, 0, get_interest_rate_curve(), oracle, True)
        txn = mock.updateTotalPrimeSupply(1, -100_000e8, 0)

        assert mock.getPrimeInterestRates(1) == (0, 0, 0)
        (pr, factors) = mock.buildPrimeRateView(1, txn.timestamp + 1)
        assert pr == (1e36, 1e36, 0)
        assert factors["totalPrimeSupply"] == 0

    def test_no_reverts_at_zero_underlying(self, mock, oracle):
        mock.initPrimeCashCurve(1, 100_000e8, 0, get_interest_rate_curve(), oracle, True)
        txn = mock.updateTotalPrimeSupply(1, 0, -100_000e8)
        assert mock.getPrimeCashFactors(1)['lastTotalUnderlyingValue'] == 0
        mock.setStoredTokenBalance(ZERO_ADDRESS, 0)

        assert mock.getPrimeInterestRates(1) == (0, 0, 0)
        (pr, factors) = mock.buildPrimeRateView(1, txn.timestamp + 1)
        assert pr == (1e36, 1e36, 0)
        assert factors["underlyingScalar"] == 1e18

    @given(
        offset=strategy("int", min_value=0, max_value=SECONDS_IN_YEAR),
        utilization=strategy("int", min_value=0, max_value=RATE_PRECISION),
    )
    def test_prime_rate_stateful_matches_view(self, mock, offset, utilization, oracle):
        txn = mock.initPrimeCashCurve(
            1,
            100_000e8,
            self.get_debt_amount(100_000e8, utilization),
            get_interest_rate_curve(),
            oracle,
            True,
        )

        (prView, _) = mock.buildPrimeRateView(1, txn.timestamp + offset)
        prStateful = mock.buildPrimeRateStateful(1, txn.timestamp + offset).return_value

        # assert that the stateful version always matches the view version
        assert prView == prStateful

        maturity = get_tref(txn.timestamp + offset)
        prSettlementView = mock.buildPrimeRateSettlementView(1, maturity, txn.timestamp + offset)
        # Before setting, this should be equal
        assert prView == prSettlementView

        chain.mine(1, timestamp=txn.timestamp + offset)
        settlementTxn = mock.buildPrimeRateSettlementStateful(1, maturity)
        settlementTs = settlementTxn.timestamp
        settlementReturnValue = settlementTxn.return_value
        chain.undo()

        # This needs to be reset, there is a tiny amount of drift here..
        prSettlementView = mock.buildPrimeRateSettlementView(1, maturity, settlementTs)

        assert settlementTxn.events["SetPrimeSettlementRate"]["currencyId"] == 1
        assert settlementTxn.events["SetPrimeSettlementRate"]["maturity"] == maturity
        assert (
            settlementTxn.events["SetPrimeSettlementRate"]["supplyFactor"]
            == prSettlementView["supplyFactor"]
        )
        assert (
            settlementTxn.events["SetPrimeSettlementRate"]["debtFactor"]
            == prSettlementView["debtFactor"]
        )
        assert prSettlementView == settlementReturnValue

    def test_prime_rate_settlement_only_sets_once(self, mock, oracle):
        utilization = 0.5e9
        txn = mock.initPrimeCashCurve(
            1,
            100_000e8,
            self.get_debt_amount(100_000e8, utilization),
            get_interest_rate_curve(),
            oracle,
            True,
        )

        maturity = get_tref(txn.timestamp + SECONDS_IN_QUARTER)
        # Cannot be set prior to maturity
        with brownie.reverts():
            chain.mine(1, timestamp=maturity - 60)
            mock.buildPrimeRateSettlementStateful(1, maturity)

        prSettlementView = mock.buildPrimeRateSettlementView(1, maturity, maturity)
        chain.mine(1, timestamp=maturity + 1000)
        settlement = mock.buildPrimeRateSettlementStateful(1, maturity).return_value

        # Stateful is settled past the view, so it has accrued more
        if utilization > 0:
            assert prSettlementView["supplyFactor"] < settlement["supplyFactor"]
            assert prSettlementView["debtFactor"] < settlement["debtFactor"]
        else:
            assert prSettlementView["supplyFactor"] == settlement["supplyFactor"]
            assert prSettlementView["debtFactor"] == settlement["debtFactor"]

        # On the second call, they are equal
        prSettlementView = mock.buildPrimeRateSettlementView(1, maturity, maturity + 1500)
        # Ignore oracle rate (3rd param)
        assert prSettlementView[0:1] == settlement[0:1]

        # Cannot be set again once set
        futureRateTxn = mock.buildPrimeRateSettlementStateful(1, maturity)
        futureRate = futureRateTxn.return_value
        assert "SetPrimeSettlementRate" not in futureRateTxn.events
        # Ignore oracle rate (3rd param)
        assert futureRate[0:1] == settlement[0:1]

    def test_accrues_faster_at_higher_utilization(self, mock, oracle):
        prevDebtRate = -1
        prevSupplyRate = -1
        prevDayAccruePositive = -1
        prevDayAccrueNegative = -1
        prevYearAccruePositive = -1
        prevYearAccrueNegative = -1

        # In each loop, utilization increases. Compare to the previous utilization
        # rate and ensure that rates are increasing as utilization increases
        for i in range(0, 10):
            utilization = i * 0.1e9
            txn = mock.initPrimeCashCurve(
                1,
                100_000e8,
                self.get_debt_amount(100_000e8, utilization),
                get_interest_rate_curve(),
                oracle,
                True,
            )

            (_, annualDebtRate, annualSupplyRate) = mock.getPrimeInterestRates(1)
            assert prevDebtRate < annualDebtRate
            assert prevSupplyRate < annualSupplyRate
            prevDebtRate = annualDebtRate
            prevSupplyRate = annualSupplyRate

            if utilization == 0:
                assert annualDebtRate == 0
                assert annualSupplyRate == 0

            (prDay, _) = mock.buildPrimeRateView(1, txn.timestamp + SECONDS_IN_DAY)
            (prYear, _) = mock.buildPrimeRateView(1, txn.timestamp + SECONDS_IN_YEAR)

            dayPositive = mock.convertToUnderlying(prDay, 100e8)
            yearPositive = mock.convertToUnderlying(prYear, 100e8)
            assert prevDayAccruePositive < dayPositive
            assert prevYearAccruePositive < yearPositive
            # Assert that the inverse holds
            assert pytest.approx(100e8, abs=1) == mock.convertFromUnderlying(prDay, dayPositive)
            assert pytest.approx(100e8, abs=1) == mock.convertFromUnderlying(prYear, yearPositive)

            prevDayAccruePositive = dayPositive
            prevYearAccruePositive = yearPositive

            dayNegative = mock.convertToUnderlying(prDay, -100e8)
            yearNegative = mock.convertToUnderlying(prYear, -100e8)
            assert dayNegative < prevDayAccrueNegative
            assert yearNegative < prevYearAccrueNegative
            assert pytest.approx(-100e8, abs=1) == mock.convertFromUnderlying(prDay, dayNegative)
            assert pytest.approx(-100e8, abs=1) == mock.convertFromUnderlying(prYear, yearNegative)
            prevDayAccrueNegative = dayNegative
            prevYearAccrueNegative = yearNegative

            chain.undo()

    @given(utilization=strategy("int", min_value=0, max_value=RATE_PRECISION))
    def test_supply_rate_is_proportional_to_utilization(self, mock, utilization, oracle):
        mock.initPrimeCashCurve(
            1,
            100_000e8,
            self.get_debt_amount(100_000e8, utilization),
            get_interest_rate_curve(feeRatePercent=0, minFeeRateBPS=0, maxFeeRateBPS=1),
            oracle,
            True,
        )

        (_, annualDebtRate, annualSupplyRate) = mock.getPrimeInterestRates(1)
        # This is true when the fee rate is zero
        assert (
            pytest.approx(math.floor((annualDebtRate * utilization) / RATE_PRECISION), abs=1)
            == annualSupplyRate
        )

    def test_update_prime_cash_curve_accrues_first(self, mock, oracle):
        txn1 = mock.initPrimeCashCurve(
            1,
            100_000e8,
            50_000e8,
            get_interest_rate_curve(feeRatePercent=0, minFeeRateBPS=0, maxFeeRateBPS=1),
            oracle,
            True,
        )
        factors1 = mock.getPrimeCashFactors(1)
        assert factors1["lastAccrueTime"] == txn1.timestamp

        txn2 = mock.updatePrimeCashCurve(1, get_interest_rate_curve())
        factors2 = mock.getPrimeCashFactors(1)
        assert factors2["lastAccrueTime"] == txn2.timestamp

    @given(
        offset=strategy("int", min_value=1, max_value=SECONDS_IN_YEAR),
        utilization=strategy("int", min_value=0, max_value=RATE_PRECISION),
        initialCash=strategy("uint", min_value=50_000e8, max_value=500_000_000e8),
    )
    def test_convert_from_and_to_underlying_are_exact(
        self, mock, oracle, offset, utilization, initialCash
    ):
        # Set the baseline totalUnderlying / initialCash ratio to 0.02, which is the cToken
        # baseline, this limits the range of rounding errors to a reasonable range
        if (100_000e8 / initialCash) < 0.02:
            initialCashHex = HexString(eth_abi.encode(['uint256'], [Wei(initialCash * 0.02e10)]), "bytes32")
            Rpc().backend._request(
                "evm_setAccountBalance", [mock.address, str(initialCashHex)]
            )

        # Tests that the underlyingScalar accrues regardless of what units the initial
        # cash amount is specified
        txn = mock.initPrimeCashCurve(
            1,
            initialCash,
            self.get_debt_amount(initialCash, utilization),
            get_interest_rate_curve(),
            oracle,
            True,
        )

        amount = initialCash
        (pr, _) = mock.buildPrimeRateView(1, txn.timestamp + offset)

        # Rounding errors are relative to the size of the amount and the ratio of the supplyFactor
        # to the debtFactor
        primeCash = mock.convertFromUnderlying(pr, amount)
        pCashToUnderlying = mock.convertToUnderlying(pr, primeCash)
        assert pytest.approx(amount, abs=3) == pCashToUnderlying

        underlying = mock.convertToUnderlying(pr, amount)
        underlyingToPCash = mock.convertFromUnderlying(pr, underlying)
        # Rounding errors occur here at one unit of supply (effectively
        # 1 / supplyFactor). This is mainly governed by the underlyingScalar
        # which sets the initial basis for the supplyFactor.
        error = math.floor(1e36 / pr["supplyFactor"]) + 3
        assert pytest.approx(amount, abs=error) == underlyingToPCash
            
        # 100_000e18 ETH
        Rpc().backend._request(
            "evm_setAccountBalance", [mock.address, "0x00000000000000000000000000000000000000000000152d02c7e14af6800000"]
        )

    @given(
        offset=strategy("int", min_value=1, max_value=SECONDS_IN_YEAR),
        utilization=strategy("int", min_value=0, max_value=RATE_PRECISION),
        initialCash=strategy("uint", min_value=50_000e8, max_value=50_000_000e8),
    )
    def test_underlying_scalar_accrues_with_value(
        self, mock, oracle, offset, utilization, initialCash
    ):
        # Tests that the underlyingScalar accrues regardless of what units the initial
        # cash amount is specified
        txn = mock.initPrimeCashCurve(
            1,
            initialCash,
            self.get_debt_amount(initialCash, utilization),
            get_interest_rate_curve(),
            oracle,
            True,
        )

        rates = mock.getPrimeInterestRates(1)

        # as total underlying increases, the debt / supply rates increase
        # accordingly holding offset and utilization constant
        (prOriginal, _) = mock.buildPrimeRateView(1, txn.timestamp + offset)
        valuePositive = mock.convertToUnderlying(prOriginal, 100e8)
        valueNegative = mock.convertToUnderlying(prOriginal, -100e8)
        for i in range(0, 6):
            scale = 1 + i / 10
            underlyingIncrease = 100_000e18 * scale
            mock.setStoredTokenBalance(ZERO_ADDRESS, underlyingIncrease)
            # reported pCash interest rates do not change
            assert rates == mock.getPrimeInterestRates(1)

            (prNew, _) = mock.buildPrimeRateView(1, txn.timestamp + offset)
            assert pytest.approx(prNew["supplyFactor"] / prOriginal["supplyFactor"]) == scale
            assert pytest.approx(prNew["debtFactor"] / prOriginal["debtFactor"]) == scale

            valuePositiveNew = mock.convertToUnderlying(prNew, 100e8)
            valueNegativeNew = mock.convertToUnderlying(prNew, -100e8)
            assert pytest.approx(valuePositiveNew / valuePositive) == scale
            assert pytest.approx(valueNegativeNew / valueNegative) == scale

    @given(
        utilization=strategy("int", min_value=0.01e9, max_value=RATE_PRECISION),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_YEAR),
    )
    def test_read_cash_balances(self, mock, oracle, utilization, offset):
        txn = mock.initPrimeCashCurve(
            1,
            100_000e8,
            self.get_debt_amount(100_000e8, utilization),
            get_interest_rate_curve(),
            oracle,
            True,
        )

        (_, annualDebtRate, _) = mock.getPrimeInterestRates(1)
        pr1 = mock.buildPrimeRateStateful(1, txn.timestamp).return_value
        positiveValue1 = mock.convertFromStorage(pr1, 100e8)
        negValue1 = mock.convertFromStorage(pr1, -100e8)

        pr2 = mock.buildPrimeRateStateful(1, txn.timestamp + offset).return_value
        positiveValue2 = mock.convertFromStorage(pr2, 100e8)
        negValue2 = mock.convertFromStorage(pr2, -100e8)

        # Positive values do not change over time
        assert positiveValue1 == positiveValue2
        # Negative values result in more and more supply value over time
        if utilization == 0:
            assert negValue2 == negValue1
        else:
            assert negValue2 < negValue1
            negUnderlying1 = mock.convertToUnderlying(pr1, negValue1)
            negUnderlying2 = mock.convertToUnderlying(pr2, negValue2)
            assert (
                pytest.approx(negUnderlying2 / negUnderlying1, rel=1e-7)
                == (annualDebtRate * offset) / (SECONDS_IN_YEAR * RATE_PRECISION) + 1
            )

    @given(
        utilization=strategy("int", min_value=0.1e9, max_value=0.9e9),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_YEAR),
        startBalance=strategy("int", min_value=-5_000e8, max_value=5_000e8, exclude=lambda x: not (-0.01e6 < x < 0.01e6)),
        netChange=strategy("int", min_value=-5_000e8, max_value=5_000e8, exclude=lambda x: not (-0.01e6 < x < 0.01e6))
    )
    def test_write_cash_values_non_settlement(
        self, mock, oracle, utilization, offset, startBalance, netChange
    ):
        initialDebt = self.get_debt_amount(100_000e8, utilization)
        txn = mock.initPrimeCashCurve(
            1, 100_000e8, initialDebt, get_interest_rate_curve(feeRatePercent=0), oracle, True
        )

        factorsBefore = mock.getPrimeCashFactors(1)
        txn1 = mock.buildPrimeRateStateful(1, txn.timestamp + offset)
        pr1 = txn1.return_value
        signedSupplyValue = mock.convertFromStorage(pr1, startBalance) + netChange

        txn = mock.convertToStorageNonSettlement(pr1, 1, startBalance, signedSupplyValue, 0)
        newStoredCashBalance = txn.return_value
        factorsAfter = mock.getPrimeCashFactors(1)

        if startBalance >= 0 and signedSupplyValue >= 0:
            # No debt changes when both are positive
            assert pytest.approx(signedSupplyValue, abs=100) == newStoredCashBalance
        if startBalance < 0 or signedSupplyValue < 0:
            assert (
                pytest.approx(mock.convertFromStorage(pr1, newStoredCashBalance), abs=5)
                == signedSupplyValue
            )
            negChange = mock.negChange(startBalance, newStoredCashBalance)
            # Ensure a negative value here to convert it properly
            negChangeSupplyValue = mock.convertFromStorage(pr1, -abs(negChange))

            if netChange != 0:
                netDebtChange = factorsAfter["totalPrimeDebt"] - factorsBefore["totalPrimeDebt"]
                assert netDebtChange == negChange
                
                # @todo this assertion is wrong
                reserveFee = 0
                for e in txn1.events['Transfer']:
                    if e['to'] == FEE_RESERVE:
                        reserveFee += e['value']

                netSupplyChange = factorsAfter["totalPrimeSupply"] - reserveFee - factorsBefore["totalPrimeSupply"]
                assert abs(netSupplyChange) == abs(negChangeSupplyValue)

                # Confirm direction of change
                assert (netDebtChange > 0 and netSupplyChange > 0) or (
                    netDebtChange < 0 and netSupplyChange < 0
                )
            else:
                assert factorsAfter["totalPrimeDebt"] == factorsBefore["totalPrimeDebt"]

    @given(utilization=strategy("int", min_value=0.1e9, max_value=0.9e9))
    def test_settle_negative_fcash_debt_accrues_proper_debt(self, mock, oracle, utilization):
        initialDebt = self.get_debt_amount(100_000e8, utilization)
        txn = mock.initPrimeCashCurve(
            1, 100_000e8, initialDebt, get_interest_rate_curve(), oracle, True
        )

        # Sets a settlement rate at the given maturity
        maturity = get_tref(txn.timestamp + SECONDS_IN_QUARTER)
        chain.mine(1, timestamp=maturity)
        prSettlementTxn = mock.buildPrimeRateSettlementStateful(1, maturity)
        factors = mock.getPrimeCashFactors(1)
        assert factors["lastAccrueTime"] == prSettlementTxn.timestamp
        settledPrimeRate = prSettlementTxn.return_value

        # Test that the same fCash balances settled at different times result in the same
        # amount of underlying owed in the future.

        # At maturity the fCash debt == underlying
        owedCashSupply = mock.convertFromUnderlying(settledPrimeRate, -100e8)
        owedUnderlying = mock.convertToUnderlying(settledPrimeRate, owedCashSupply)
        assert pytest.approx(owedUnderlying, abs=10) == -100e8

        # This is the stored cash balance at settlement
        (_, annualDebtRate, _) = mock.getPrimeInterestRates(1)
        storedCashBalanceAtSettlement = mock.convertToStorageValue(settledPrimeRate, owedCashSupply)

        # At maturity + 1 quarter amount owed = underlying + 1 quarter of interest
        (presentPrimeRate, _) = mock.buildPrimeRateView(1, maturity + SECONDS_IN_QUARTER)
        newPrimeSupply = mock.convertFromStorage(presentPrimeRate, storedCashBalanceAtSettlement)
        newUnderlying = mock.convertToUnderlying(presentPrimeRate, newPrimeSupply)

        assert newUnderlying < owedUnderlying
        assert (
            pytest.approx(newUnderlying / owedUnderlying)
            == (annualDebtRate * SECONDS_IN_QUARTER) / (SECONDS_IN_YEAR * RATE_PRECISION) + 1
        )

        # assert that the convert settled fcash returns the same result
        assert (
            pytest.approx(newPrimeSupply, abs=1)
            == mock.convertSettledfCash(
                presentPrimeRate, 1, maturity, -100e8, maturity + SECONDS_IN_QUARTER
            ).return_value
        )

    @given(utilization=strategy("int", min_value=0.1e9, max_value=0.9e9))
    def test_settlement_increases_total_debt_outstanding(self, mock, oracle, utilization):
        initialDebt = self.get_debt_amount(100_000e8, utilization)
        txn = mock.initPrimeCashCurve(
            1, 100_000e8, initialDebt, get_interest_rate_curve(), oracle, True
        )
        maturity = get_tref(txn.timestamp + SECONDS_IN_QUARTER)

        mock.updateTotalfCashDebtOutstanding(1, maturity, 105_000e8)
        mock.setMarket(1, maturity, get_market_state(maturity, totalfCash=100_000e8))

        (prView, factorsBefore) = mock.buildPrimeRateView(1, maturity)
        chain.mine(1, timestamp=maturity)
        # Additional fCash nets off the fCash amount in simulate_init_markets
        simulate_init_markets(mock, 1)
        txn = mock.buildPrimeRateSettlementStateful(1, maturity)
        pr = txn.return_value
        factorsAfter = mock.getPrimeCashFactors(1)

        # Assert scalars are approx equal
        assert pytest.approx(prView[0]) == pr[0]
        assert pytest.approx(prView[1]) == pr[1]

        assert mock.getTotalfCashDebtOutstanding(1, maturity) == 0
        # Settled 5_000e8 fCash amount, supply figures are different. There is a bit of
        # drift due to passage of time.
        assert (
            pytest.approx(
                mock.convertToUnderlying(pr, factorsAfter["totalPrimeSupply"])
                - mock.convertToUnderlying(pr, factorsBefore["totalPrimeSupply"]),
                abs=50_000
            )
            == 5_000e8
        )

        debtBefore = mock.convertToUnderlying(
            pr, mock.convertFromStorage(pr, -factorsBefore["totalPrimeDebt"])
        )
        debtAfter = mock.convertToUnderlying(
            pr, mock.convertFromStorage(pr, -factorsAfter["totalPrimeDebt"])
        )

        assert pytest.approx(debtBefore - debtAfter, abs=5) == 5_000e8

    @given(
        utilization=strategy("int", min_value=0.1e9, max_value=0.9e9),
        offset=strategy("int", min_value=0, max_value=SECONDS_IN_YEAR),
        previousCashBalance=strategy("int", min_value=-5_000e8, max_value=5_000e8),
        positiveSettled=strategy("int", min_value=0, max_value=5_000e8),
        negativeSettled=strategy("int", min_value=-5_000e8, max_value=0),
    )
    def test_settle_cash_repayment_updates_properly(
        self,
        mock,
        oracle,
        utilization,
        offset,
        previousCashBalance,
        positiveSettled,
        negativeSettled,
    ):
        initialDebt = self.get_debt_amount(100_000e8, utilization)
        mock.initPrimeCashCurve(1, 100_000e8, initialDebt, get_interest_rate_curve(
            feeRatePercent=0
        ), oracle, True)
        chain.mine(1, timedelta=offset)
        factorsBefore = mock.getPrimeCashFactors(1)

        txn = mock.convertToStorageInSettlement(
            1, previousCashBalance, positiveSettled, negativeSettled
        )

        factorsAfter = mock.getPrimeCashFactors(1)
        (pr, _) = mock.buildPrimeRateView(1, txn.timestamp)
        assert txn.return_value == mock.convertToStorageValue(
            pr, previousCashBalance + positiveSettled + negativeSettled
        )

        if previousCashBalance < 0:
            negativeSettled = negativeSettled + previousCashBalance
        else:
            positiveSettled = positiveSettled + previousCashBalance

        reserveFee = 0
        for e in txn.events['Transfer']:
            if e['to'] == FEE_RESERVE:
                reserveFee += e['value']

        if max(negativeSettled, -positiveSettled) < 0:
            # This is the net supply change from debt repayment
            # during settlement
            supplyChange = (
                factorsAfter["totalPrimeSupply"]
                - reserveFee
                - factorsBefore["totalPrimeSupply"]
            )
            assert supplyChange < 0
            assert supplyChange == max(negativeSettled, -positiveSettled)
        else:
            assert negativeSettled == 0 or positiveSettled == 0

    def test_prime_cash_equality_holds(self, mock, oracle):
        chain.snapshot()
        numCompounds = 500

        for i in [3, 6, 9]:
            utilization = i * 0.1e9
            initialCashHex = HexString(eth_abi.encode(['uint256'], [Wei(500_000_000e18)]), "bytes32")
            Rpc().backend._request(
                "evm_setAccountBalance", [mock.address, str(initialCashHex)]
            )
            initialDebt = self.get_debt_amount(500_000_000e8, utilization)
            mock.initPrimeCashCurve(1, 500_000_000e8, initialDebt, get_interest_rate_curve(), oracle, True)
        
            txn = mock.buildPrimeRateStateful(1, chain.time())
            initTime = txn.timestamp

            for i in range(0, numCompounds):
                chain.mine(1, timedelta=math.floor(SECONDS_IN_YEAR / numCompounds))
                txn = mock.buildPrimeRateStateful(1, chain.time())

            finalTime = txn.timestamp
            assert pytest.approx(finalTime - initTime, abs=500) == SECONDS_IN_YEAR
            pr = txn.return_value
            factors = mock.getPrimeCashFactors(1)
            totalPrimeSupplyUnderlying = mock.convertToUnderlying(pr, factors["totalPrimeSupply"])
            totalPrimeDebtUnderlying = mock.convertDebtStorageToUnderlying(pr, -factors["totalPrimeDebt"])

            diff = totalPrimeSupplyUnderlying + totalPrimeDebtUnderlying - factors['lastTotalUnderlyingValue']
            # This should hold for a large number of compoundings but the test takes a long time to run
            assert diff < 1e8
            assert diff / factors["lastTotalUnderlyingValue"] < 1e-6
            
            # logging.info("Utilization: {}, Percent Underlying: {:8f}%, Abs Diff: {:8f}".format(
            #     utilization / 1e9,
            #     diff * 100 / factors['lastTotalUnderlyingValue'],
            #     diff / 1e8
            #     )
            # )

            chain.revert()