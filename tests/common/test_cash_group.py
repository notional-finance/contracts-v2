import random

import brownie
import pytest
from brownie.test import given, strategy
from tests.common.params import *


@pytest.fixture(scope="module", autouse=True)
def cashGroup(MockCashGroup, accounts):
    return accounts[0].deploy(MockCashGroup)


@pytest.fixture(scope="module", autouse=True)
def aggregator(MockAggregator, accounts):
    aggregator = accounts[0].deploy(MockAggregator, 18)
    aggregator.setAnswer(1e18)

    return aggregator


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_invalid_max_market(cashGroup):
    # Tests that we cant go above the max index
    with brownie.reverts():
        cg = list(BASE_CASH_GROUP)
        cg[1] = 10
        cashGroup.isValidMaturity(cg, 10000, 1)


def test_maturity_before_block_time(cashGroup):
    cg = list(BASE_CASH_GROUP)
    isValid = cashGroup.isValidMaturity(cg, START_TIME - 1, START_TIME)
    assert not isValid


def test_maturity_non_mod(cashGroup):
    cg = list(BASE_CASH_GROUP)
    isValid = cashGroup.isValidMaturity(cg, 1601856000 + (91 * SECONDS_IN_DAY), 1601856000)
    assert not isValid


@given(
    quarters=strategy("uint40", min_value=0, max_value=800),
    blockTime=strategy("uint40", min_value=START_TIME),
    maxMarketIndex=strategy("uint8", min_value=1, max_value=9),
)
def test_valid_maturity(cashGroup, quarters, blockTime, maxMarketIndex):
    cg = list(BASE_CASH_GROUP)
    cg[1] = maxMarketIndex
    tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
    maturity = tRef + quarters * (90 * SECONDS_IN_DAY)
    isValid = cashGroup.isValidMaturity(cg, maturity, blockTime)

    validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
    assert (maturity in validMarkets) == isValid


@given(
    days=strategy("uint40", min_value=0, max_value=7500),
    blockTime=strategy("uint40", min_value=START_TIME),
    maxMarketIndex=strategy("uint8", min_value=1, max_value=9),
)
def test_bit_number(cashGroup, days, blockTime, maxMarketIndex):
    tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
    maturity = tRef + days * SECONDS_IN_DAY
    cg = list(BASE_CASH_GROUP)
    cg[1] = maxMarketIndex

    bitNum = cashGroup.getIdiosyncraticBitNumber(cg, maturity, blockTime)
    maxMaturity = tRef + cashGroup.getTradedMarket(maxMarketIndex)

    if maturity > maxMaturity:
        assert bitNum == 0

    if maturity < blockTime:
        assert bitNum == 0

    # convert the bitnum back to a maturity
    if bitNum:
        maturityRef = cashGroup.getMaturityFromBitNum(blockTime, bitNum)
        assert maturity == maturityRef


def test_build_cash_group(cashGroup, aggregator):
    rateStorage = (aggregator.address, 18, False, 0, 0, 18, 18)
    cashGroup.setAssetRateMapping(1, rateStorage)

    for i in range(0, 50):
        cashGroupParameters = (
            random.randint(0, 9),  # 0 maxMarketIndex,
            random.randint(1, 255),  # 1 rateOracleTimeWindowMin,
            random.randint(1, 100),  # 2 liquidityFeeBPS,
            random.randint(1, 100),  # 3 liquidityTokenHaircut,
            random.randint(1, 100),  # 4 debtBufferBPS,
            random.randint(1, 100),  # 5 fCashHaircutBPS,
            random.randint(1, 20000),  # 6 rateScalar
        )

        cashGroupBytes = (
            cashGroupParameters[-1].to_bytes(2, "big")
            + bytes(list(reversed(cashGroupParameters[0:-1])))
        ).hex()
        cashGroupBytes = cashGroupBytes.rjust(64, "0")

        cashGroup.setCashGroup(1, cashGroupParameters)

        cg = cashGroup.buildCashGroup(1)
        assert cg[0] == 1  # cash group id
        assert cg[1] == cashGroupParameters[0]  # Max market index
        assert cg[3] == "0x" + cashGroupBytes

        assert cashGroupParameters[1] * 60 == cashGroup.getRateOracleTimeWindow(cg)
        assert cashGroupParameters[2] * BASIS_POINT == cashGroup.getLiquidityFee(
            cg, NORMALIZED_RATE_TIME
        )
        assert cashGroupParameters[3] == cashGroup.getLiquidityHaircut(cg, NORMALIZED_RATE_TIME)
        assert cashGroupParameters[4] * BASIS_POINT == cashGroup.getDebtBuffer(cg)
        assert cashGroupParameters[5] * BASIS_POINT == cashGroup.getfCashHaircut(cg)
        assert cashGroupParameters[-1] == cashGroup.getRateScalar(cg, NORMALIZED_RATE_TIME)
