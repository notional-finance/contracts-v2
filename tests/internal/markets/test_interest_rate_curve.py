import math
import brownie
import pytest
from brownie.test import given, strategy
from tests.constants import BASIS_POINT
from tests.helpers import get_interest_rate_curve


class TestInterestRateCurve:
    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @pytest.fixture(scope="module", autouse=True)
    def mock(self, MockInterestRateCurve, accounts):
        return accounts[0].deploy(MockInterestRateCurve)

    def test_fails_on_set_invalid_market(self, mock):
        with brownie.reverts():
            mock.setNextInterestRateParameters(1, 8, get_interest_rate_curve())

        with brownie.reverts():
            mock.setNextInterestRateParameters(1, 0, get_interest_rate_curve())

    def test_fails_on_set_invalid_parameters(self, mock):
        with brownie.reverts():
            # Reverts due to kinkUtilization1 > kinkUtilization2
            mock.setNextInterestRateParameters(
                1, 1, get_interest_rate_curve(kinkUtilization1=75, kinkUtilization2=25)
            )

        with brownie.reverts():
            # Reverts due to kinkUtilization2 > 100
            mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve(kinkUtilization2=101))

        with brownie.reverts():
            # Reverts due to kinkUtilization2 > 100
            mock.setNextInterestRateParameters(
                1, 1, get_interest_rate_curve(kinkUtilization1=25, kinkUtilization2=25)
            )

        with brownie.reverts():
            # Reverts due to kinkRate1 > kinkRate2
            mock.setNextInterestRateParameters(
                1, 1, get_interest_rate_curve(kinkRate1=200, kinkRate2=199)
            )

        with brownie.reverts():
            # Reverts due to kinkRate1 == kinkRate2
            mock.setNextInterestRateParameters(
                1, 1, get_interest_rate_curve(kinkRate1=200, kinkRate2=200)
            )

        with brownie.reverts():
            # Reverts due to minFeeRate > maxFeeRate
            mock.setNextInterestRateParameters(
                1, 1, get_interest_rate_curve(minFeeRateBPS=6, maxFeeRateBPS=1)
            )

        with brownie.reverts():
            # Reverts due to minFeeRate > maxFeeRate
            mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve(feeRatePercent=101))

    def test_sets_all_market_indexes(self, mock):
        for i in range(1, 8):
            mock.setNextInterestRateParameters(1, i, get_interest_rate_curve(feeRatePercent=i))

        for i in range(1, 8):
            params = mock.getNextInterestRateParameters(1, i)
            assert params["feeRatePercent"] == i

    @given(marketIndex=strategy("uint", min_value=1, max_value=7))
    def test_set_next_interest_rate_params(self, mock, marketIndex):
        # Init all the interest rate params
        for i in range(1, 8):
            mock.setNextInterestRateParameters(1, i, get_interest_rate_curve(feeRatePercent=i))
        paramsBefore = [mock.getNextInterestRateParameters(1, i) for i in range(1, 8)]

        # Set the params to a new value set of values
        newParams = (25, 50, 32, 64, 100, 10, 50, 5)
        mock.setNextInterestRateParameters(1, marketIndex, newParams)

        paramsAfter = [mock.getNextInterestRateParameters(1, i) for i in range(1, 8)]

        for i in range(1, 8):
            if i != marketIndex:
                assert paramsBefore[i - 1] == paramsAfter[i - 1]
            else:
                assert paramsAfter[i - 1] == (
                    0.25e9,
                    0.5e9,
                    0.03125e9,
                    0.0625e9,
                    0.25e9,
                    0.005e9,
                    0.125e9,
                    5,
                )

    def test_sets_prime_cash_parameters(self, mock):
        mock.setPrimeCashInterestRateParameters(1, get_interest_rate_curve())
        assert mock.getPrimeCashInterestRateParameters(1) == (
            0.25e9,
            0.75e9,
            0.0625e9,
            0.125e9,
            0.25e9,
            0.001e9,
            0.005e9,
            5,
        )

        mock.setActiveInterestRateParameters(1)
        assert mock.getPrimeCashInterestRateParameters(1) == (
            0.25e9,
            0.75e9,
            0.0625e9,
            0.125e9,
            0.25e9,
            0.001e9,
            0.005e9,
            5,
        )

    def test_sets_active_interest_rate_params(self, mock):
        mock.setPrimeCashInterestRateParameters(1, get_interest_rate_curve(feeRatePercent=0))

        for i in range(1, 8):
            mock.setNextInterestRateParameters(1, i, get_interest_rate_curve(feeRatePercent=i))
            assert mock.getActiveInterestRateParameters(1, i) == ([0] * 8)

        # Tests that all parameters, including prime cash rates are preserved
        paramsBefore = [mock.getNextInterestRateParameters(1, i) for i in range(1, 8)]
        mock.setActiveInterestRateParameters(1)
        activeAfter = [mock.getActiveInterestRateParameters(1, i) for i in range(1, 8)]

        assert paramsBefore == activeAfter

    def test_get_interest_rate_reverts(self, mock):
        mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve())

        # Reverts on max rate unset
        with brownie.reverts():
            mock.getInterestRates(1, 1, True, 0.5e9)

    def test_get_interest_rate_reverts_on_over_utilization(self, mock):
        mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve())
        mock.setActiveInterestRateParameters(1)

        # Reverts on over 100% utilization
        with brownie.reverts():
            mock.getInterestRates(1, 1, True, 1.0001e9)

    @given(utilization=strategy("uint", min_value=0, max_value=1e9), isBorrow=strategy("bool"))
    def test_gets_borrow_interest_rates(self, mock, utilization, isBorrow):
        mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve())
        mock.setActiveInterestRateParameters(1)

        params = mock.getActiveInterestRateParameters(1, 1)
        (preFee, postFee) = mock.getInterestRates(1, 1, isBorrow, utilization)

        assert preFee >= 0
        assert postFee >= 0
        if isBorrow:
            assert preFee < postFee
            assert postFee - preFee <= params["maxFeeRate"]
            assert postFee - preFee >= params["minFeeRate"]
        else:
            assert preFee >= postFee
            assert preFee - postFee <= params["maxFeeRate"]
            # At the very lower bound, the preFee and postFee round down
            # to zero
            if postFee > 20:
                assert preFee - postFee >= params["minFeeRate"]

        if 0 <= utilization and utilization < params["kinkUtilization1"]:
            assert 0 <= preFee and preFee <= params["kinkRate1"]
        elif utilization < params["kinkUtilization2"]:
            assert params["kinkRate1"] < preFee and preFee <= params["kinkRate2"]
        else:
            assert params["kinkRate2"] < preFee and preFee <= params["maxRate"]

    @given(utilization=strategy("uint", min_value=0, max_value=1e9))
    def test_get_utilization_from_interest_rate(self, mock, utilization):
        mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve())
        mock.setActiveInterestRateParameters(1)

        (preFee, _) = mock.getInterestRates(1, 1, True, utilization)
        utilization_ = mock.getUtilizationFromInterestRate(1, 1, preFee)

        assert pytest.approx(utilization_, abs=10) == utilization

    @given(maxRateUnits=strategy("uint", min_value=0, max_value=255))
    def test_max_interest_rate_range(self, mock, maxRateUnits):
        mock.setNextInterestRateParameters(1, 1, get_interest_rate_curve(
            kinkRate1=64,
            kinkRate2=128,
            maxRateUnits=maxRateUnits
        ))
        params = mock.getNextInterestRateParameters(1, 1)
        if maxRateUnits <= 150:
            assert params['maxRate'] == maxRateUnits * 25 * BASIS_POINT
        else:
            assert params['maxRate'] == 150 * 25 * BASIS_POINT + (maxRateUnits - 150) * 150 * BASIS_POINT
        assert params['kinkRate1'] == math.floor(params['maxRate'] * 64 / 256)
        assert params['kinkRate2'] == math.floor(params['maxRate'] * 128 / 256)