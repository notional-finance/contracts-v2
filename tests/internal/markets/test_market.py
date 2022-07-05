import math

import brownie
import pytest
from brownie.test import given, strategy
from tests.constants import (
    CASH_GROUP_PARAMETERS,
    MARKETS,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    SETTLEMENT_DATE,
    START_TIME,
)
from tests.helpers import get_market_state


@pytest.mark.market
class TestMarket:
    @pytest.fixture(scope="module", autouse=True)
    def market(self, MockMarket, MockCToken, cTokenV2Aggregator, accounts):
        market = accounts[0].deploy(MockMarket)
        ctoken = accounts[0].deploy(MockCToken, 8)
        # This is the identity rate
        ctoken.setAnswer(1e18)
        aggregator = cTokenV2Aggregator.deploy(ctoken.address, {"from": accounts[0]})

        rateStorage = (aggregator.address, 8)
        market.setAssetRateMapping(1, rateStorage)
        market.setCashGroup(1, CASH_GROUP_PARAMETERS)

        return market

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_build_market(self, market):
        marketStorage = get_market_state(MARKETS[0], previousTradeTime=1e9)
        market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)
        result = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)

        assert result[1] == MARKETS[0]
        assert result[2] == marketStorage[2]
        assert result[3] == marketStorage[3]
        assert result[4] == marketStorage[4]
        assert result[5] == marketStorage[5]
        assert result[6] == marketStorage[6]  # Oracle rate has not changed
        assert result[7] == marketStorage[7]

    @given(
        lastImpliedRate=strategy(
            "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
        ),
        oracleRate=strategy(
            "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
        ),
    )
    @pytest.mark.skip_coverage
    def test_oracle_rate(self, market, lastImpliedRate, oracleRate):
        timeWindow = 600  # Time window set to 10 min
        marketStorage = get_market_state(
            MARKETS[0],
            lastImpliedRate=lastImpliedRate,
            oracleRate=oracleRate,
            previousTradeTime=START_TIME,
        )
        market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        timeTicks = [START_TIME + timeDelta for timeDelta in range(0, timeWindow + 10, 10)]
        for newTime in timeTicks:
            result = market.buildMarket(1, MARKETS[0], newTime, True, timeWindow)

            if newTime - START_TIME > timeWindow:
                assert result[6] == lastImpliedRate
            else:
                # Rate oracle should be averaged in as the time ticks forward
                timeDiff = newTime - START_TIME
                weightedAvg = math.trunc(
                    timeDiff / timeWindow * lastImpliedRate
                    + (1 - timeDiff / timeWindow) * oracleRate
                )
                assert pytest.approx(weightedAvg, abs=10) == result[6]

    def test_fail_on_set_overflows(self, market):
        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], totalfCash=2 ** 81)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], totalAssetCash=2 ** 81)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], totalLiquidity=2 ** 81)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], lastImpliedRate=2 ** 33)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], oracleRate=2 ** 33)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], previousTradeTime=2 ** 33)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

    def test_fail_on_set_negative_values(self, market):
        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], totalfCash=-1)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], totalAssetCash=-1)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

        with brownie.reverts():
            marketStorage = get_market_state(MARKETS[0], totalLiquidity=-1)
            market.setMarketStorage(1, SETTLEMENT_DATE, marketStorage)

    @given(assetCash=strategy("uint", min_value=0, max_value=100e18))
    def test_add_liquidity(self, market, assetCash):
        marketState = get_market_state(MARKETS[0])
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)

        (newMarket, tokens, fCash) = market.addLiquidity(marketState, assetCash).return_value
        assert newMarket[2] == marketState[2] - fCash
        assert newMarket[3] == marketState[3] + assetCash
        assert newMarket[4] == marketState[4] + tokens
        # No change to other parameters
        assert newMarket[5] == marketState[5]
        assert newMarket[6] == marketState[6]
        assert newMarket[7] == marketState[7]

        assert pytest.approx(math.trunc(newMarket[2] * tokens / newMarket[4]), rel=1e-15) == -fCash
        assert (
            pytest.approx(math.trunc(newMarket[3] * tokens / newMarket[4]), rel=1e-15) == assetCash
        )

    @given(tokensToRemove=strategy("uint", min_value=0, max_value=1e18))
    def test_remove_liquidity(self, market, tokensToRemove):
        marketState = get_market_state(MARKETS[0])
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)

        (newMarket, assetCash, fCash) = market.removeLiquidity(
            marketState, tokensToRemove
        ).return_value
        assert newMarket[2] == marketState[2] - fCash
        assert newMarket[3] == marketState[3] - assetCash
        assert newMarket[4] == marketState[4] - tokensToRemove
        # No change to other parameters
        assert newMarket[5] == marketState[5]
        assert newMarket[6] == marketState[6]
        assert newMarket[7] == marketState[7]

        assert (
            pytest.approx(math.trunc(marketState[2] * tokensToRemove / marketState[4]), rel=1e-15)
            == fCash
        )
        assert (
            pytest.approx(math.trunc(marketState[3] * tokensToRemove / marketState[4]), rel=1e-15)
            == assetCash
        )

    def test_liquidity_failures(self, market):
        marketState = list(get_market_state(MARKETS[0]))

        with brownie.reverts():
            market.addLiquidity(marketState, -1)

        with brownie.reverts():
            market.removeLiquidity(marketState, -1)

        with brownie.reverts():
            market.removeLiquidity(marketState, 100e18)

        with brownie.reverts():
            marketState[4] = 0
            market.addLiquidity(marketState, 1e9)

    @given(fCashAmount=strategy("int", min_value=-10000e8, max_value=-1e8))
    def test_borrow_state(self, market, fCashAmount):
        marketState = get_market_state(
            MARKETS[0], totalLiquidity=1000000e8, totalfCash=1000000e8, totalAssetCash=1000000e8
        )
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)
        cashGroup = market.buildCashGroupView(1)

        (newMarket, assetCash, fee) = market.calculateTrade(
            marketState, cashGroup, fCashAmount, 30 * SECONDS_IN_DAY, 1
        )
        assert assetCash > 0
        assert fee > 0
        assert newMarket[2] == marketState[2] - fCashAmount
        assert newMarket[3] == marketState[3] - (assetCash + fee)
        assert newMarket[4] == marketState[4]
        # Implied rates have increased
        assert newMarket[5] > marketState[5]

        # Oracle rate unchanged
        assert newMarket[6] == marketState[6]
        # Trade time has changed
        assert newMarket[7] > marketState[7]

    @given(fCashAmount=strategy("int", min_value=1e8, max_value=10000e8))
    def test_lend_state(self, market, fCashAmount):
        marketState = get_market_state(
            MARKETS[0], totalLiquidity=1000000e8, totalfCash=1000000e8, totalAssetCash=1000000e8
        )
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)
        cashGroup = market.buildCashGroupView(1)

        (newMarket, assetCash, fee) = market.calculateTrade(
            marketState, cashGroup, fCashAmount, 30 * SECONDS_IN_DAY, 1
        )
        assert assetCash < 0
        assert fee > 0

        assert newMarket[2] == marketState[2] - fCashAmount
        assert newMarket[3] == marketState[3] - (assetCash + fee)
        assert newMarket[4] == marketState[4]
        # Implied rates have decreased
        assert newMarket[5] < marketState[5]

        # Oracle rate unchanged
        assert newMarket[6] == marketState[6]
        # Trade time has changed
        assert newMarket[7] > marketState[7]

    def test_max_market_proportion(self, market):
        # Sets the proportion at 0.96
        marketState = get_market_state(MARKETS[0], totalfCash=0.99e15, totalAssetCash=0.01e15)
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)
        cashGroup = market.buildCashGroupView(1)

        # Borrowing at max proportion should fail
        (_, assetCash, _) = market.calculateTrade(
            marketState, cashGroup, -1e8, 30 * SECONDS_IN_DAY, 1
        )
        assert assetCash == 0

        # Lending at max proportion should succeed
        (_, assetCash, _) = market.calculateTrade(
            marketState, cashGroup, 100e8, 30 * SECONDS_IN_DAY, 1
        )
        assert assetCash < 0
