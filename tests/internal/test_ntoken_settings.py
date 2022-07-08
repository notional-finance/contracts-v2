import math
import random

import brownie
import pytest
from brownie.convert.datatypes import HexString, Wei
from brownie.test import given, strategy
from tests.constants import START_TIME


@pytest.mark.ntoken
class TestNTokenSettings:
    @pytest.fixture(scope="module", autouse=True)
    def nToken(self, MockNTokenHandler, accounts):
        return accounts[0].deploy(MockNTokenHandler)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @given(currencyId=strategy("uint16", min_value=1), tokenAddress=strategy("address"))
    def test_set_ntoken_setters(self, nToken, currencyId, tokenAddress):
        if tokenAddress == HexString(0, "bytes20"):
            return

        # This has assertions inside
        nToken.setNTokenAddress(currencyId, tokenAddress)
        assert nToken.nTokenAddress(currencyId) == tokenAddress
        (
            currencyIdStored,
            incentives,
            lastInitializeTime,
            arrayLength,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert incentives == 0
        assert lastInitializeTime == 0
        assert arrayLength == 0
        assert parameters == "0x00000000000000"

        nToken.setIncentiveEmissionRate(tokenAddress, 100_000, START_TIME)
        nToken.updateNTokenCollateralParameters(currencyId, 40, 90, 96, 50, 95)

        (
            currencyIdStored,
            incentives,
            lastInitializeTime,
            arrayLength,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert incentives == 100_000
        assert lastInitializeTime == 0
        assert bytearray(parameters)[0] == 95
        assert bytearray(parameters)[1] == 50
        assert bytearray(parameters)[2] == 96
        assert bytearray(parameters)[3] == 90
        assert bytearray(parameters)[4] == 40
        assert arrayLength == 0

        nToken.setArrayLengthAndInitializedTime(tokenAddress, 5, START_TIME)

        (
            currencyIdStored,
            incentives,
            lastInitializeTime,
            arrayLength,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert incentives == 100_000
        assert lastInitializeTime == START_TIME
        assert bytearray(parameters)[0] == 95
        assert bytearray(parameters)[1] == 50
        assert bytearray(parameters)[2] == 96
        assert bytearray(parameters)[3] == 90
        assert bytearray(parameters)[4] == 40
        assert arrayLength == 5

        nToken.updateNTokenCollateralParameters(currencyId, 41, 91, 97, 51, 96)
        (
            currencyIdStored,
            incentives,
            lastInitializeTime,
            arrayLength,
            parameters,
        ) = nToken.getNTokenContext(tokenAddress)
        assert currencyIdStored == currencyId
        assert incentives == 100_000
        assert lastInitializeTime == START_TIME
        assert bytearray(parameters)[0] == 96
        assert bytearray(parameters)[1] == 51
        assert bytearray(parameters)[2] == 97
        assert bytearray(parameters)[3] == 91
        assert bytearray(parameters)[4] == 41
        assert arrayLength == 5

    def test_initialize_ntoken_supply(self, nToken, accounts):
        # When we initialize the nToken supply amount the accumulatedNOTEPerNToken
        # should be set to zero
        tokenAddress = accounts[9]
        nToken.setIncentiveEmissionRate(tokenAddress, 100_000, START_TIME)

        txn = nToken.changeNTokenSupply(tokenAddress, 100e8, START_TIME)
        assert txn.return_value == 0
        (
            totalSupply,
            accumulatedNOTEPerNToken,
            lastAccumulatedTime,
        ) = nToken.getStoredNTokenSupplyFactors(tokenAddress)
        assert totalSupply == 100e8
        assert accumulatedNOTEPerNToken == 0
        assert lastAccumulatedTime == START_TIME

    def test_incentives_dont_update_at_blocktime(self, nToken, accounts):
        # Supply changes at the same block time should not affect the accumulated NOTE per ntoken
        # as long as we accumulate at the same block time
        tokenAddress = accounts[9]
        nToken.setIncentiveEmissionRate(tokenAddress, 100_000, START_TIME)

        nToken.changeNTokenSupply(tokenAddress, 1000e8, START_TIME + 100)
        (
            totalSupply,
            accumulatedNOTEPerNToken1,
            lastAccumulatedTime,
        ) = nToken.getStoredNTokenSupplyFactors(tokenAddress)
        assert totalSupply == 1000e8

        nToken.changeNTokenSupply(tokenAddress, 1000e18, START_TIME + 100)
        (
            totalSupply,
            accumulatedNOTEPerNToken2,
            lastAccumulatedTime,
        ) = nToken.getStoredNTokenSupplyFactors(tokenAddress)
        assert totalSupply == 1000e8 + 1000e18

        nToken.changeNTokenSupply(tokenAddress, -500e18, START_TIME + 100)
        (
            totalSupply,
            accumulatedNOTEPerNToken3,
            lastAccumulatedTime,
        ) = nToken.getStoredNTokenSupplyFactors(tokenAddress)
        assert totalSupply == Wei(1000e8) + Wei(1000e18) - Wei(500e18)

        assert accumulatedNOTEPerNToken1 == accumulatedNOTEPerNToken2
        assert accumulatedNOTEPerNToken2 == accumulatedNOTEPerNToken3

    def test_accumulate_note_per_ntoken(self, nToken, accounts):
        tokenAddress = accounts[9]
        totalSupply = 11000e8
        blockTime = START_TIME

        nToken.setIncentiveEmissionRate(tokenAddress, 100_000, blockTime)
        nToken.changeNTokenSupply(tokenAddress, totalSupply, blockTime)
        prevAccumulatedNOTEPerNToken = 0

        for _ in range(0, 10):
            timeDelta = random.randint(1, 86400)
            supplyChange = random.randint(-1000e8, 1000e8)
            blockTime = blockTime + timeDelta
            totalSupply = totalSupply + supplyChange

            nToken.changeNTokenSupply(tokenAddress, supplyChange, blockTime)
            (
                totalSupply_,
                accumulatedNOTEPerNToken_,
                lastAccumulatedTime_,
            ) = nToken.getStoredNTokenSupplyFactors(tokenAddress)

            assert lastAccumulatedTime_ == blockTime
            assert totalSupply_ == totalSupply
            assert accumulatedNOTEPerNToken_ > prevAccumulatedNOTEPerNToken
            prevAccumulatedNOTEPerNToken = accumulatedNOTEPerNToken_

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
        with brownie.reverts("PT: annualized anchor rates length"):
            nToken.setInitializationParameters(1, [1] * 10, [1] * 10)

        with brownie.reverts("PT: proportions length"):
            nToken.setInitializationParameters(1, [1] * 2, [1] * 10)

        with brownie.reverts("PT: invalid proportion"):
            nToken.setInitializationParameters(1, [0.02e9], [0])
            nToken.setInitializationParameters(1, [0.02e9], [1.1e9])

        with brownie.reverts("NT: anchor rate zero"):
            nToken.setInitializationParameters(1, [0], [0.5e9])

        with brownie.reverts("PT: invalid proportion"):
            nToken.setInitializationParameters(1, [1.1e9], [1.1e9])

    @given(maxMarketIndex=strategy("uint", min_value=0, max_value=7))
    def test_init_parameters_values(self, nToken, maxMarketIndex):
        currencyId = 1
        initialAnnualRates = [random.randint(0, 0.4e9) for i in range(0, maxMarketIndex)]
        proportions = [random.randint(0.75e9, 0.999e9) for i in range(0, maxMarketIndex)]

        nToken.setInitializationParameters(currencyId, initialAnnualRates, proportions)

        (storedRateAnchors, storedProportions) = nToken.getInitializationParameters(
            currencyId, maxMarketIndex
        )
        assert storedRateAnchors == initialAnnualRates
        assert storedProportions == proportions
