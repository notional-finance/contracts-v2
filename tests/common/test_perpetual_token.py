import math
import random

import brownie
import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def perpetualToken(MockPerpetualToken, accounts):
    return accounts[0].deploy(MockPerpetualToken)


@given(currencyId=strategy("uint16"), tokenAddress=strategy("address"))
def test_set_token_address(perpetualToken, currencyId, tokenAddress):
    # This has assertions inside
    perpetualToken.setPerpetualTokenAddress(currencyId, tokenAddress)

    assert perpetualToken.getPerpetualTokenAddress(currencyId) == tokenAddress
    (currencyIdStored, totalSupply) = perpetualToken.getPerpetualTokenCurrencyIdAndSupply(
        tokenAddress
    )
    assert currencyIdStored == currencyId
    assert totalSupply == 0


def test_deposit_parameters_failures(perpetualToken):
    with brownie.reverts("PT: deposit share length"):
        perpetualToken.setDepositParameters(1, [1] * 10, [1] * 10)

    with brownie.reverts("PT: leverage share length"):
        perpetualToken.setDepositParameters(1, [1] * 2, [1] * 10)

    with brownie.reverts("PT: leverage threshold"):
        perpetualToken.setDepositParameters(1, [1] * 2, [0] * 2)

    with brownie.reverts("PT: leverage threshold"):
        perpetualToken.setDepositParameters(1, [1] * 2, [1.1e9] * 2)

    with brownie.reverts("PT: deposit shares sum"):
        perpetualToken.setDepositParameters(1, [1e8, 100], [100] * 2)


@given(maxMarketIndex=strategy("uint", min_value=5, max_value=5))
def test_deposit_parameters(perpetualToken, maxMarketIndex):
    currencyId = 1
    randNums = [random.random() for i in range(0, maxMarketIndex)]
    basis = sum(randNums)
    depositShares = [math.trunc(r / basis * 1e7) for r in randNums]
    leverageThresholds = [random.randint(1e6, 1e7) for i in range(0, maxMarketIndex)]

    perpetualToken.setDepositParameters(currencyId, depositShares, leverageThresholds)

    (storedDepositShares, storedLeverageThresholds) = perpetualToken.getDepositParameters(
        currencyId, maxMarketIndex
    )
    assert storedDepositShares == depositShares
    assert storedLeverageThresholds == leverageThresholds


def test_init_parameters_failures(perpetualToken):
    with brownie.reverts("PT: rate anchors length"):
        perpetualToken.setInitializationParameters(1, [1] * 10, [1] * 10)

    with brownie.reverts("PT: proportions length"):
        perpetualToken.setInitializationParameters(1, [1] * 2, [1] * 10)

    with brownie.reverts("PT: invalid rate anchor"):
        perpetualToken.setInitializationParameters(1, [1] * 2, [0] * 2)

    with brownie.reverts("PT: invalid proportion"):
        perpetualToken.setInitializationParameters(1, [1.1e9], [0])

    with brownie.reverts("PT: invalid proportion"):
        perpetualToken.setInitializationParameters(1, [1.1e9], [1.1e9])


@given(maxMarketIndex=strategy("uint", min_value=0, max_value=9))
def test_init_parameters_values(perpetualToken, maxMarketIndex):
    currencyId = 1
    rateAnchors = [random.randint(1.01e9, 1.2e9) for i in range(0, maxMarketIndex)]
    proportions = [random.randint(0.75e9, 0.999e9) for i in range(0, maxMarketIndex)]

    perpetualToken.setInitializationParameters(currencyId, rateAnchors, proportions)

    (storedRateAnchors, storedProportions) = perpetualToken.getInitializationParameters(
        currencyId, maxMarketIndex
    )
    assert storedRateAnchors == rateAnchors
    assert storedProportions == proportions
