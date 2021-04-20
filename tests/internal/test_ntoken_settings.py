import math
import random

import brownie
import pytest
from brownie.test import given, strategy
from tests.constants import START_TIME


@pytest.mark.ntoken
class TestNTokenSettings:
    @pytest.fixture(scope="module", autouse=True)
    def nToken(self, MockNTokenHandler, accounts):
        return accounts[0].deploy(MockNTokenHandler)

    @given(currencyId=strategy("uint16"), tokenAddress=strategy("address"))
    @pytest.mark.only
    def test_set_perpetual_token_setters(self, nToken, currencyId, tokenAddress):
        # This has assertions inside
        nToken.setNTokenAddress(currencyId, tokenAddress)
        # TODO: more secure test is to set random bits and then ensure that our
        # current settings make it properly

        assert nToken.nTokenAddress(currencyId) == tokenAddress
        (
            currencyIdStored,
            totalSupply,
            incentives,
            lastInitializeTime,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert totalSupply == 0
        assert incentives == 0
        assert lastInitializeTime == 0
        assert parameters == "0x00000000000000"

        nToken.setIncentiveEmissionRate(tokenAddress, 100_000)
        nToken.updateNTokenCollateralParameters(currencyId, 40, 90, 96, 50, 95)

        (
            currencyIdStored,
            totalSupply,
            incentives,
            lastInitializeTime,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert totalSupply == 0
        assert incentives == 100_000
        assert lastInitializeTime == 0
        assert bytearray(parameters)[0] == 95
        assert bytearray(parameters)[1] == 50
        assert bytearray(parameters)[2] == 96
        assert bytearray(parameters)[3] == 90
        assert bytearray(parameters)[4] == 40
        assert bytearray(parameters)[5] == 0

        nToken.setArrayLengthAndInitializedTime(tokenAddress, 5, START_TIME)

        (
            currencyIdStored,
            totalSupply,
            incentives,
            lastInitializeTime,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert totalSupply == 0
        assert incentives == 0.01e9
        assert lastInitializeTime == START_TIME
        assert bytearray(parameters)[0] == 95
        assert bytearray(parameters)[1] == 50
        assert bytearray(parameters)[2] == 96
        assert bytearray(parameters)[3] == 90
        assert bytearray(parameters)[4] == 40
        assert bytearray(parameters)[5] == 5

        nToken.updateNTokenCollateralParameters(currencyId, 41, 91, 97, 51, 96)
        (
            currencyIdStored,
            totalSupply,
            incentives,
            lastInitializeTime,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert totalSupply == 0
        assert incentives == 0.01e9
        assert lastInitializeTime == START_TIME
        assert bytearray(parameters)[0] == 96
        assert bytearray(parameters)[1] == 51
        assert bytearray(parameters)[2] == 97
        assert bytearray(parameters)[3] == 91
        assert bytearray(parameters)[4] == 41
        assert bytearray(parameters)[5] == 5

        nToken.changeNTokenSupply(tokenAddress, 1e8)
        (
            currencyIdStored,
            totalSupply,
            incentives,
            lastInitializeTime,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert totalSupply == 1e8
        assert incentives == 0.01e9
        assert lastInitializeTime == START_TIME
        assert bytearray(parameters)[0] == 96
        assert bytearray(parameters)[1] == 51
        assert bytearray(parameters)[2] == 97
        assert bytearray(parameters)[3] == 91
        assert bytearray(parameters)[4] == 41
        assert bytearray(parameters)[5] == 5

        nToken.changeNTokenSupply(tokenAddress, -0.5e8)
        (
            currencyIdStored,
            totalSupply,
            incentives,
            lastInitializeTime,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert totalSupply == 0.5e8
        assert incentives == 0.01e9
        assert lastInitializeTime == START_TIME
        assert bytearray(parameters)[0] == 96
        assert bytearray(parameters)[1] == 51
        assert bytearray(parameters)[2] == 97
        assert bytearray(parameters)[3] == 91
        assert bytearray(parameters)[4] == 41
        assert bytearray(parameters)[5] == 5

        with brownie.reverts():
            nToken.changeNTokenSupply(tokenAddress, -1e8)

    def test_deposit_parameters_failures(self, nToken):
        with brownie.reverts("PT: deposit share length"):
            nToken.setDepositParameters(1, [1] * 10, [1] * 10)

        with brownie.reverts("PT: leverage share length"):
            nToken.setDepositParameters(1, [1] * 2, [1] * 10)

        with brownie.reverts("PT: leverage threshold"):
            nToken.setDepositParameters(1, [1] * 2, [0] * 2)

        with brownie.reverts("PT: leverage threshold"):
            nToken.setDepositParameters(1, [1] * 2, [1.1e9] * 2)

        with brownie.reverts("PT: deposit shares sum"):
            nToken.setDepositParameters(1, [1e8, 100], [100] * 2)

    @given(maxMarketIndex=strategy("uint", min_value=2, max_value=7))
    def test_deposit_parameters(self, nToken, maxMarketIndex):
        currencyId = 1
        randNums = [random.random() for i in range(0, maxMarketIndex)]
        basis = sum(randNums)
        depositShares = [math.trunc(r / basis * 1e7) for r in randNums]
        depositShares[0] = depositShares[0] + (1e8 - sum(depositShares))
        leverageThresholds = [random.randint(1e6, 1e7) for i in range(0, maxMarketIndex)]

        nToken.setDepositParameters(currencyId, depositShares, leverageThresholds)

        (storedDepositShares, storedLeverageThresholds) = nToken.getDepositParameters(
            currencyId, maxMarketIndex
        )
        assert storedDepositShares == depositShares
        assert storedLeverageThresholds == leverageThresholds

    def test_init_parameters_failures(self, nToken):
        with brownie.reverts("PT: rate anchors length"):
            nToken.setInitializationParameters(1, [1] * 10, [1] * 10)

        with brownie.reverts("PT: proportions length"):
            nToken.setInitializationParameters(1, [1] * 2, [1] * 10)

        with brownie.reverts("PT: invalid rate anchor"):
            nToken.setInitializationParameters(1, [1] * 2, [0] * 2)

        with brownie.reverts("PT: invalid proportion"):
            nToken.setInitializationParameters(1, [1.1e9], [0])

        with brownie.reverts("PT: invalid proportion"):
            nToken.setInitializationParameters(1, [1.1e9], [1.1e9])

    @given(maxMarketIndex=strategy("uint", min_value=0, max_value=7))
    def test_init_parameters_values(self, nToken, maxMarketIndex):
        currencyId = 1
        rateAnchors = [random.randint(1.01e9, 1.2e9) for i in range(0, maxMarketIndex)]
        proportions = [random.randint(0.75e9, 0.999e9) for i in range(0, maxMarketIndex)]

        nToken.setInitializationParameters(currencyId, rateAnchors, proportions)

        (storedRateAnchors, storedProportions) = nToken.getInitializationParameters(
            currencyId, maxMarketIndex
        )
        assert storedRateAnchors == rateAnchors
        assert storedProportions == proportions
