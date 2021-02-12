import random

import brownie
import pytest
from brownie.test import given, strategy
from tests.common.params import *


@pytest.fixture(scope="module", autouse=True)
def mockCToken(MockCToken, accounts):
    ctoken = accounts[0].deploy(MockCToken, 8)
    ctoken.setAnswer(1e18)
    return ctoken


@pytest.fixture(scope="module", autouse=True)
def aggregator(cTokenAggregator, mockCToken, accounts):
    return cTokenAggregator.deploy(mockCToken.address, {"from": accounts[0]})


@pytest.fixture(scope="module", autouse=True)
def cashGroup(MockCashGroup, accounts):
    return accounts[0].deploy(MockCashGroup)


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

    if isValid:
        (index, idiosyncratic) = cashGroup.getMarketIndex(cg, maturity, blockTime)
        assert not idiosyncratic
        assert validMarkets[index - 1] == maturity


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

    isValid = cashGroup.isValidIdiosyncraticMaturity(cg, maturity, blockTime)
    maxMaturity = tRef + cashGroup.getTradedMarket(maxMarketIndex)

    if maturity > maxMaturity:
        assert not isValid

    if maturity < blockTime:
        assert not isValid

    # convert the bitnum back to a maturity
    if isValid:
        (bitNum, _) = cashGroup.getBitNumFromMaturity(blockTime, maturity)
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

        (cg, markets) = cashGroup.buildCashGroup(1)
        assert cg[0] == 1  # cash group id
        assert cg[1] == cashGroupParameters[0]  # Max market index
        assert cg[3] == "0x" + cashGroupBytes
        assert len(markets) == cg[1]

        assert cashGroupParameters[1] * 60 == cashGroup.getRateOracleTimeWindow(cg)
        assert cashGroupParameters[2] * BASIS_POINT == cashGroup.getLiquidityFee(
            cg, NORMALIZED_RATE_TIME
        )
        assert cashGroupParameters[3] == cashGroup.getLiquidityHaircut(cg, NORMALIZED_RATE_TIME)
        assert cashGroupParameters[4] * BASIS_POINT == cashGroup.getDebtBuffer(cg)
        assert cashGroupParameters[5] * BASIS_POINT == cashGroup.getfCashHaircut(cg)
        assert cashGroupParameters[-1] == cashGroup.getRateScalar(cg, NORMALIZED_RATE_TIME)


@given(
    maxMarketIndex=strategy("uint8", min_value=1, max_value=9),
    blockTime=strategy("uint32", min_value=START_TIME),
)
def test_get_market(cashGroup, aggregator, maxMarketIndex, blockTime):
    rateStorage = (aggregator.address, 18, False, 0, 0, 18, 18)
    cashGroup.setAssetRateMapping(1, rateStorage)
    cashGroup.setCashGroup(
        1,
        (
            maxMarketIndex,
            random.randint(1, 255),  # 1 rateOracleTimeWindowMin,
            random.randint(1, 100),  # 2 liquidityFeeBPS,
            random.randint(1, 100),  # 3 liquidityTokenHaircut,
            random.randint(1, 100),  # 4 debtBufferBPS,
            random.randint(1, 100),  # 5 fCashHaircutBPS,
            random.randint(1, 20000),  # 6 rateScalar
        ),
    )

    tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
    validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
    (cg, markets) = cashGroup.buildCashGroup(1)

    for m in validMarkets:
        randBigNum = random.randint(1e18, 5e18)
        randSmallNum = random.randint(1e8, 1e9)
        # TODO: test initialization here
        cashGroup.setMarketState(
            cg[0],
            m,
            (randBigNum, randBigNum + 1, randSmallNum, randSmallNum + 1, blockTime - 100),
            randBigNum + 3,
        )

    (cg, markets) = cashGroup.buildCashGroup(1)
    # TODO: test if we get it twice...
    for i in range(0, len(validMarkets)):
        needsLiquidity = True if random.randint(0, 1) else False
        market = cashGroup.getMarket(cg, markets, i + 1, blockTime, needsLiquidity)
        (marketStored, totalLiquidity) = cashGroup.getMarketState(1, validMarkets[i])
        assert market[2] == marketStored[0]
        assert market[3] == marketStored[1]
        if needsLiquidity:
            assert market[4] == totalLiquidity
        else:
            assert market[4] == 0

        assert market[5] == marketStored[2]
        # NOTE: don't need to test oracleRate
        assert market[7] == marketStored[4]
        # Assert market has updated is set to false
        assert not market[8]


@given(
    maxMarketIndex=strategy("uint8", min_value=1, max_value=9),
    blockTime=strategy("uint32", min_value=START_TIME),
    # this is a per block interest rate of 0.2% to 42%, (rate = 2102400 * supplyRate / 1e18)
    supplyRate=strategy("uint", min_value=1e9, max_value=2e11),
)
def test_get_oracle_rate(cashGroup, aggregator, mockCToken, maxMarketIndex, blockTime, supplyRate):
    mockCToken.setSupplyRate(supplyRate)
    cRate = supplyRate * 2102400 / 1e9

    rateStorage = (aggregator.address, 18, False, 0, 0, 18, 18)
    cashGroup.setAssetRateMapping(1, rateStorage)
    cashGroup.setCashGroup(
        1,
        (
            maxMarketIndex,
            1,  # 1 rateOracleTimeWindowMin,
            random.randint(1, 100),  # 2 liquidityFeeBPS,
            random.randint(1, 100),  # 3 liquidityTokenHaircut,
            random.randint(1, 100),  # 4 debtBufferBPS,
            random.randint(1, 100),  # 5 fCashHaircutBPS,
            random.randint(1, 20000),  # 6 rateScalar
        ),
    )

    tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
    validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
    impliedRates = {}
    (cg, markets) = cashGroup.buildCashGroup(1)

    for m in validMarkets:
        lastImpliedRate = random.randint(1e8, 1e9)
        impliedRates[m] = lastImpliedRate

        cashGroup.setMarketState(cg[0], m, (1e18, 1e18, lastImpliedRate, 0, blockTime - 1000), 1e18)

    for m in validMarkets:
        # If we fall on a valid market then the rate must match exactly
        rate = cashGroup.getOracleRate(cg, markets, m, blockTime)
        assert rate == impliedRates[m]

    for i in range(0, 5):
        randomM = random.randint(blockTime + 1, validMarkets[-1])
        rate = cashGroup.getOracleRate(cg, markets, randomM, blockTime)
        (marketIndex, idiosyncratic) = cashGroup.getMarketIndex(cg, randomM, blockTime)

        if not idiosyncratic:
            assert rate == impliedRates[randomM]
        elif marketIndex != 1:
            shortM = validMarkets[marketIndex - 2]
            longM = validMarkets[marketIndex - 1]
            assert rate > min(impliedRates[shortM], impliedRates[longM])
            assert rate < max(impliedRates[shortM], impliedRates[longM])
        else:
            assert rate > min(cRate, impliedRates[validMarkets[0]])
            assert rate < max(cRate, impliedRates[validMarkets[0]])
