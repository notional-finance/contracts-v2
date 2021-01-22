import brownie
import pytest
from brownie.test import given, strategy

# Jan 1 2021
START_TIME = 1609459200
SECONDS_IN_DAY = 86400
SECONDS_IN_YEAR = SECONDS_IN_DAY * 360


@pytest.fixture(scope="module", autouse=True)
def cashGroup(MockCashGroup, accounts):
    return accounts[0].deploy(MockCashGroup)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_invalid_max_market(cashGroup):
    # Tests that we cant go above the max index
    with brownie.reverts():
        cg = (0, 0, 0, 9, 0)
        cashGroup.isValidMaturity(cg, 10000, 1)


def test_maturity_before_block_time(cashGroup):
    cg = (0, 0, 0, 8, 0)
    isValid = cashGroup.isValidMaturity(cg, START_TIME - 1, START_TIME)
    assert not isValid


def test_maturity_non_mod(cashGroup):
    cg = (0, 0, 0, 8, 0)
    isValid = cashGroup.isValidMaturity(cg, 1601856000 + (91 * SECONDS_IN_DAY), 1601856000)
    assert not isValid


@given(
    quarters=strategy("uint40", min_value=0, max_value=800),
    blockTime=strategy("uint40", min_value=START_TIME),
    maxMarketIndex=strategy("uint8", min_value=0, max_value=8),
)
def test_valid_maturity(cashGroup, quarters, blockTime, maxMarketIndex):
    cg = (0, 0, 0, maxMarketIndex, 0)
    tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
    maturity = tRef + quarters * (90 * SECONDS_IN_DAY)
    isValid = cashGroup.isValidMaturity(cg, maturity, blockTime)

    validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(0, maxMarketIndex)]
    assert (maturity in validMarkets) == isValid


@given(
    days=strategy("uint40", min_value=0, max_value=7500),
    blockTime=strategy("uint40", min_value=START_TIME),
    maxMarketIndex=strategy("uint8", min_value=0, max_value=8),
)
def test_bit_number(cashGroup, days, blockTime, maxMarketIndex):
    tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
    maturity = tRef + days * SECONDS_IN_DAY
    cg = (0, 0, 0, maxMarketIndex, 0)

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
