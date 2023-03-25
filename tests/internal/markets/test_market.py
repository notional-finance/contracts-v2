import math
import random

import brownie
import pytest
from brownie import Contract
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from tests.constants import (
    CASH_GROUP_PARAMETERS,
    MARKETS,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    SETTLEMENT_DATE,
    START_TIME,
    ZERO_ADDRESS
)
from brownie.network import Rpc
from tests.helpers import get_interest_rate_curve, get_market_state


@pytest.mark.market
class TestMarket:
    @pytest.fixture(scope="module", autouse=True)
    def market(self, MockMarket, MockSettingsLib, UnderlyingHoldingsOracle, accounts):
        settingsLib = MockSettingsLib.deploy({"from": accounts[0]})
        market = MockMarket.deploy(settingsLib, {"from": accounts[0]})
        mock = Contract.from_abi("mock", market.address, MockSettingsLib.abi + market.abi, owner=accounts[0])

        oracle = UnderlyingHoldingsOracle.deploy(mock.address, ZERO_ADDRESS, {"from": accounts[0]})

        # 100_000e18 ETH
        Rpc().backend._request(
            "evm_setAccountBalance", [mock.address, "0x00000000000000000000000000000000000000000000152d02c7e14af6800000"]
        )
        mock.initPrimeCashCurve(
            1, 100_000e8, 0, get_interest_rate_curve(), oracle, True, {"from": accounts[0]}
        )
        mock.setCashGroup(1, CASH_GROUP_PARAMETERS)

        return mock


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
            marketStorage = get_market_state(MARKETS[0], totalPrimeCash=2 ** 81)
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
            marketStorage = get_market_state(MARKETS[0], totalPrimeCash=-1)
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
        market.setInterestRateParameters(1, 1, get_interest_rate_curve())
        marketState = get_market_state(
            MARKETS[0],
            totalLiquidity=1000000e8,
            totalfCash=1000000e8,
            totalPrimeCash=1000000e8,
            lastImpliedRate=93750000,
            oracleRate=93750000,
        )
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)
        cashGroup = market.buildCashGroupView(1)

        (newMarket, cashToAccount, cashToReserve) = market.calculateTrade(
            marketState, cashGroup, fCashAmount, 30 * SECONDS_IN_DAY, 1
        )
        assert cashToAccount > 0
        assert cashToReserve > 0
        assert newMarket['totalfCash'] == marketState['totalfCash'] - fCashAmount
        assert pytest.approx(newMarket['totalPrimeCash'] - marketState['totalPrimeCash'] + cashToReserve + cashToAccount, abs=10) == 0
        assert newMarket['totalLiquidity'] == marketState['totalLiquidity']
        assert newMarket['lastImpliedRate'] > marketState['lastImpliedRate']
        assert newMarket['oracleRate'] == marketState['oracleRate']
        assert newMarket['previousTradeTime'] > marketState['previousTradeTime']

    @given(fCashAmount=strategy("int", min_value=1e8, max_value=10000e8))
    def test_lend_state(self, market, fCashAmount):
        market.setInterestRateParameters(1, 1, get_interest_rate_curve())
        marketState = get_market_state(
            MARKETS[0],
            totalLiquidity=1000000e8,
            totalfCash=1000000e8,
            totalPrimeCash=1000000e8,
            lastImpliedRate=93750000,
            oracleRate=93750000,
        )
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)
        cashGroup = market.buildCashGroupView(1)

        (newMarket, cashToAccount, cashToReserve) = market.calculateTrade(
            marketState, cashGroup, fCashAmount, 30 * SECONDS_IN_DAY, 1
        )
        assert cashToAccount < 0
        assert cashToReserve > 0
        assert newMarket['totalfCash'] == marketState['totalfCash'] - fCashAmount
        assert pytest.approx(newMarket['totalPrimeCash'] - marketState['totalPrimeCash'] + cashToReserve + cashToAccount, abs=10) == 0
        assert newMarket['totalLiquidity'] == marketState['totalLiquidity']
        assert newMarket['lastImpliedRate'] < marketState['lastImpliedRate']
        assert newMarket['oracleRate'] == marketState['oracleRate']
        assert newMarket['previousTradeTime'] > marketState['previousTradeTime']

    def test_max_market_proportion(self, market):
        market.setInterestRateParameters(1, 1, get_interest_rate_curve())
        marketState = get_market_state(MARKETS[0], totalfCash=0.99e15, totalPrimeCash=0.01e15)
        market.setMarketStorage(1, SETTLEMENT_DATE, marketState)
        marketState = market.buildMarket(1, MARKETS[0], START_TIME, True, 1)
        cashGroup = market.buildCashGroupView(1)

        # Borrowing above max utilization should fail
        (newMarket, assetCash, _) = market.calculateTrade(
            marketState, cashGroup, -0.02e15, 30 * SECONDS_IN_DAY, 1
        )

        assert assetCash == 0
        assert newMarket[1:] == marketState[1:]

    @given(
        marketIndex=strategy("uint8", min_value=1, max_value=7),
        utilization=strategy(
            "uint256", min_value=0.33 * RATE_PRECISION, max_value=0.66 * RATE_PRECISION
        ),
    )
    def test_fcash_convergence(self, market, marketIndex, utilization):
        marketIndex = 1
        market.setInterestRateParameters(1, 1, get_interest_rate_curve())

        netCashAmount = Wei(1e8 * random.randint(-100000, 100000))
        totalfCash = 1e18
        totalCashUnderlying = totalfCash * (RATE_PRECISION - utilization) / utilization
        cashGroup = market.buildCashGroupView(1)
        interestRate = market.getInterestRateFromUtilization(1, 1, utilization)

        marketState = get_market_state(
            MARKETS[marketIndex - 1],
            totalfCash=totalfCash,
            totalPrimeCash=totalCashUnderlying,
            lastImpliedRate=interestRate,
        )

        fCashAmount = market.getfCashAmountGivenCashAmount(
            1,
            totalfCash,
            totalCashUnderlying,
            netCashAmount,
            marketIndex,
            marketState[1] - START_TIME,  # Time to Maturity
        )

        (_, cashAmount, _) = market.calculateTrade(
            marketState, cashGroup, fCashAmount, marketState[1] - START_TIME, marketIndex
        )

        assert pytest.approx(cashAmount, abs=1) == netCashAmount
