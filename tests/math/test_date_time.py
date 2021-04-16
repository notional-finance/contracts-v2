import pytest
from brownie.test import given, strategy
from tests.constants import CASH_GROUP_PARAMETERS, SECONDS_IN_DAY, START_TIME
from tests.helpers import get_cash_group_with_max_markets


class TestDateTime:
    @pytest.fixture(scope="module", autouse=True)
    def cashGroup(self, MockCashGroup, MockCToken, cTokenAggregator, accounts):
        cg = accounts[0].deploy(MockCashGroup)

        ctoken = accounts[0].deploy(MockCToken, 8)
        # This is the identity rate
        ctoken.setAnswer(1e18)
        aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})
        rateStorage = (aggregator.address, 8)

        cg.setAssetRateMapping(1, rateStorage)
        return cg

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_maturity_before_block_time(self, cashGroup):
        cashGroupParameters = list(CASH_GROUP_PARAMETERS)
        cashGroup.setCashGroup(1, cashGroupParameters)
        (cg, _) = cashGroup.buildCashGroupView(1)
        isValid = cashGroup.isValidMaturity(cg, START_TIME - 1, START_TIME)
        assert not isValid

    def test_maturity_non_mod(self, cashGroup):
        cashGroupParameters = list(CASH_GROUP_PARAMETERS)
        cashGroup.setCashGroup(1, cashGroupParameters)
        (cg, _) = cashGroup.buildCashGroupView(1)
        isValid = cashGroup.isValidMaturity(cg, 1601856000 + (91 * SECONDS_IN_DAY), 1601856000)
        assert not isValid

    @given(
        quarters=strategy("uint40", min_value=0, max_value=800),
        blockTime=strategy("uint40", min_value=START_TIME),
        maxMarketIndex=strategy("uint8", min_value=2, max_value=7),
    )
    def test_valid_maturity(self, cashGroup, quarters, blockTime, maxMarketIndex):
        cashGroupParameters = get_cash_group_with_max_markets(maxMarketIndex)
        cashGroup.setCashGroup(1, cashGroupParameters)
        (cg, _) = cashGroup.buildCashGroupView(1)

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
        maxMarketIndex=strategy("uint8", min_value=2, max_value=7),
    )
    def test_bit_number(self, cashGroup, days, blockTime, maxMarketIndex):
        cashGroupParameters = get_cash_group_with_max_markets(maxMarketIndex)
        cashGroup.setCashGroup(1, cashGroupParameters)
        (cg, _) = cashGroup.buildCashGroupView(1)

        tRef = blockTime - blockTime % (90 * SECONDS_IN_DAY)
        maturity = tRef + days * SECONDS_IN_DAY

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
