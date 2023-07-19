import math
import random

import brownie
import pytest
from brownie.network import Chain
from brownie.network.contract import Contract
from brownie.test import given, strategy
from tests.constants import (
    BASIS_POINT,
    CASH_GROUP_PARAMETERS,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    START_TIME,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_interest_rate_curve,
    get_market_state,
    get_tref,
    setup_internal_mock,
)

chain = Chain()


class TestCashGroupGetters:
    @pytest.fixture(scope="module", autouse=True)
    def cashGroup(self, MockCashGroup, MockSettingsLib, MockERC20, UnderlyingHoldingsOracle, accounts):
        settings = MockSettingsLib.deploy({"from": accounts[0]})
        mock = MockCashGroup.deploy(settings, {"from": accounts[0]})
        mock = Contract.from_abi(
            "mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0]
        )

        setup_internal_mock(mock)

        token = MockERC20.deploy("token", "token", 8, 0, {"from": accounts[0]})
        oracle = UnderlyingHoldingsOracle.deploy(mock.address, token.address, {"from": accounts[0]})
        token.transfer(mock, 100_000e8, {"from": accounts[0]})
        mock.initPrimeCashCurve(
            5, 100_000e8, 0, get_interest_rate_curve(), oracle, True, {"from": accounts[0]}
        )

        return mock

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_invalid_max_market_index_settings(self, cashGroup):
        cashGroupParameters = list(CASH_GROUP_PARAMETERS)

        with brownie.reverts():
            # Cannot set max markets to 1
            cashGroupParameters[0] = 1
            cashGroup.setCashGroup(1, cashGroupParameters)

        with brownie.reverts():
            # Cannot set max markets past max value
            cashGroupParameters[0] = 10
            cashGroup.setCashGroup(1, cashGroupParameters)

        with brownie.reverts():
            # Cannot reduce max markets
            cashGroupParameters[0] = 4
            cashGroup.setCashGroup(1, cashGroupParameters)
            cashGroupParameters[0] = 3
            cashGroup.setCashGroup(1, cashGroupParameters)

    def test_invalid_fcash_haircut_settings(self, cashGroup):
        cashGroupParameters = list(CASH_GROUP_PARAMETERS)

        with brownie.reverts():
            # cannot be higher than fcash discount
            cashGroupParameters[7] = cashGroupParameters[5]
            cashGroup.setCashGroup(1, cashGroupParameters)

        with brownie.reverts():
            # cannot be higher than fcash discount
            cashGroupParameters[7] = cashGroupParameters[5] + 1
            cashGroup.setCashGroup(1, cashGroupParameters)

    def test_build_cash_group(self, cashGroup):
        for i in range(1, 50):
            maxMarketIndex = random.randint(2, 7)
            cashGroupParameters = [
                maxMarketIndex,
                random.randint(1, 255),  # 1 rateOracleTimeWindowMin
                random.randint(1, 255),  # 2 max discount factor
                random.randint(1, 100),  # 3 reserveFeeShare
                random.randint(1, 255),  # 4 debtBuffer
                random.randint(1, 255),  # 5 fCashHaircut
                random.randint(1, 255),  # 6 min oracle rate 
                random.randint(1, 255),  # 7 liquidation fcash haircut
                random.randint(1, 255),  # 8 liquidation debt buffer
                random.randint(1, 255),  # 9 max oracle rate
            ]

            # ensure liquidation fcash is less that fcash haircut
            if cashGroupParameters[7] >= cashGroupParameters[5]:
                cashGroupParameters[7] = cashGroupParameters[5] - 1

            if cashGroupParameters[8] >= cashGroupParameters[4]:
                cashGroupParameters[8] = cashGroupParameters[4] - 1

            if cashGroupParameters[6] >= cashGroupParameters[9]:
                cashGroupParameters[6] = cashGroupParameters[9] - 1

            cashGroup.setCashGroup(5, cashGroupParameters)
            cg = cashGroup.buildCashGroupView(5)
            assert cg[0] == 5  # cash group id
            assert cg[1] == cashGroupParameters[0]  # Max market index

            assert cashGroupParameters[1] * 300 == cashGroup.getRateOracleTimeWindow(cg)
            assert 1e9 - cashGroupParameters[2] * 5 * BASIS_POINT == cashGroup.getMaxDiscountFactor(cg)
            assert cashGroupParameters[3] == cashGroup.getReserveFeeShare(cg)
            assert cashGroupParameters[4] * 25 * BASIS_POINT == cashGroup.getDebtBuffer(cg)
            assert cashGroupParameters[5] * 25 * BASIS_POINT == cashGroup.getfCashHaircut(cg)
            assert cashGroupParameters[6] * 25 * BASIS_POINT == cashGroup.getMinOracleRate(cg)
            assert cashGroupParameters[7] * 25 * BASIS_POINT == cashGroup.getLiquidationfCashHaircut(
                cg
            )
            assert cashGroupParameters[8] * 25 * BASIS_POINT == cashGroup.getLiquidationDebtBuffer(
                cg
            )
            assert cashGroupParameters[9] * 25 * BASIS_POINT == cashGroup.getMaxOracleRate(
                cg
            )

            storage = cashGroup.deserializeCashGroupStorage(5)
            assert storage == cashGroupParameters
            chain.undo()

    @given(
        maxMarketIndex=strategy("uint8", min_value=2, max_value=7),
        blockTime=strategy("uint32", min_value=START_TIME),
    )
    def test_load_market(self, cashGroup, maxMarketIndex, blockTime):
        cashGroup.setCashGroup(5, get_cash_group_with_max_markets(maxMarketIndex))

        tRef = get_tref(blockTime)
        validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
        cg = cashGroup.buildCashGroupView(5)

        for m in validMarkets:
            settlementDate = tRef + 90 * SECONDS_IN_DAY
            cashGroup.setMarketState(cg[0], settlementDate, get_market_state(m))

        cg = cashGroup.buildCashGroupView(5)

        for i in range(0, len(validMarkets)):
            needsLiquidity = True if random.randint(0, 1) else False
            market = cashGroup.loadMarket(cg, i + 1, needsLiquidity, blockTime)
            marketStored = cashGroup.getMarketState(cg[0], validMarkets[i], blockTime, 1)

            # Assert values are the same
            assert market[2] == marketStored[2]
            assert market[3] == marketStored[3]
            if needsLiquidity:
                assert market[4] == marketStored[4]
            else:
                assert market[4] == 0

            assert market[5] == marketStored[5]
            # NOTE: don't need to test oracleRate
            assert market[7] == marketStored[7]

    @given(
        maxMarketIndex=strategy("uint8", min_value=2, max_value=7),
        blockTime=strategy("uint32", min_value=START_TIME),
        utilization=strategy("uint", min_value=1e9, max_value=2e11),
    )
    def test_get_oracle_rate(self, cashGroup, maxMarketIndex, blockTime, utilization):
        initialDebt = math.floor(100_000e8 * utilization / RATE_PRECISION)
        cashGroup.setCashGroup(5, get_cash_group_with_max_markets(maxMarketIndex))
        cashGroup.updateTotalPrimeDebt(5, initialDebt * 2, initialDebt)

        tRef = get_tref(blockTime)
        validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
        impliedRates = {}
        cg = cashGroup.buildCashGroupView(5)

        for m in validMarkets:
            lastImpliedRate = random.randint(1e8, 1e9)
            impliedRates[m] = lastImpliedRate
            settlementDate = tRef + 90 * SECONDS_IN_DAY

            cashGroup.setMarketState(
                cg[0],
                settlementDate,
                get_market_state(
                    m, lastImpliedRate=lastImpliedRate, previousTradeTime=blockTime - 7000
                ),
            )

        for m in validMarkets:
            # If we fall on a valid market then the rate must match exactly
            rate = cashGroup.calculateOracleRate(cg, m, blockTime)
            assert rate == impliedRates[m]

        for i in range(0, 5):
            randomM = random.randint(blockTime + 1, validMarkets[-1])
            rate = cashGroup.calculateOracleRate(cg, randomM, blockTime)
            (marketIndex, idiosyncratic) = cashGroup.getMarketIndex(
                maxMarketIndex, randomM, blockTime
            )

            if not idiosyncratic:
                assert rate == impliedRates[randomM]
            elif marketIndex != 1:
                shortM = validMarkets[marketIndex - 2]
                longM = validMarkets[marketIndex - 1]
                assert rate > min(impliedRates[shortM], impliedRates[longM])
                assert rate < max(impliedRates[shortM], impliedRates[longM])
            else:
                assert rate > min(
                    cg["primeRate"]["oracleSupplyRate"], impliedRates[validMarkets[0]]
                )
                assert rate < max(
                    cg["primeRate"]["oracleSupplyRate"], impliedRates[validMarkets[0]]
                )
