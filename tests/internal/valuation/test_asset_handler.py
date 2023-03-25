import math

import brownie
import pytest
from brownie.network.contract import Contract
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import (
    FCASH_ASSET_TYPE,
    MARKETS,
    SECONDS_IN_DAY,
    SETTLEMENT_DATE,
    START_TIME,
    START_TIME_TREF,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_fcash_token,
    get_liquidity_token,
    get_market_state,
    get_portfolio_array,
    impliedRateStrategy,
    setup_internal_mock,
)

chain = Chain()


@pytest.mark.valuation
class TestAssetHandler:
    @pytest.fixture(scope="class", autouse=True)
    def assetLibrary(self, MockFreeCollateral, MockSettingsLib, accounts):
        settings = MockSettingsLib.deploy({"from": accounts[0]})
        mock = MockFreeCollateral.deploy(settings, {"from": accounts[0]})
        mock = Contract.from_abi(
            "mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0]
        )

        setup_internal_mock(mock)

        return mock

    @pytest.fixture(scope="class", autouse=True)
    def cashGroups(self, assetLibrary):
        return [
            (
                assetLibrary.buildCashGroupView(1),
                [
                    assetLibrary.getMarket(1, MARKETS[0], SETTLEMENT_DATE),
                    assetLibrary.getMarket(1, MARKETS[1], SETTLEMENT_DATE),
                    assetLibrary.getMarket(1, MARKETS[2], SETTLEMENT_DATE),
                ],
            ),
            (
                assetLibrary.buildCashGroupView(2),
                [
                    assetLibrary.getMarket(2, MARKETS[0], SETTLEMENT_DATE),
                    assetLibrary.getMarket(2, MARKETS[1], SETTLEMENT_DATE),
                    assetLibrary.getMarket(2, MARKETS[2], SETTLEMENT_DATE),
                ],
            ),
            (
                assetLibrary.buildCashGroupView(3),
                [
                    assetLibrary.getMarket(3, MARKETS[0], SETTLEMENT_DATE),
                    assetLibrary.getMarket(3, MARKETS[1], SETTLEMENT_DATE),
                    assetLibrary.getMarket(3, MARKETS[2], SETTLEMENT_DATE),
                ],
            ),
        ]

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_settlement_date(self, assetLibrary):
        with brownie.reverts():
            # invalid asset type
            assetLibrary.getSettlementDate((1, START_TIME_TREF, 0, 0, 0, 0))

        # fcash settlement date
        assert MARKETS[1] == assetLibrary.getSettlementDate(
            (1, MARKETS[1], FCASH_ASSET_TYPE, 0, 0, 0)
        )
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[0], 2, 0, 0, 0))
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[1], 3, 0, 0, 0))
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[2], 4, 0, 0, 0))
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[3], 5, 0, 0, 0))
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[4], 6, 0, 0, 0))
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[5], 7, 0, 0, 0))
        assert SETTLEMENT_DATE == assetLibrary.getSettlementDate((1, MARKETS[6], 8, 0, 0, 0))

        with brownie.reverts():
            # invalid asset type
            assetLibrary.getSettlementDate((1, START_TIME_TREF, 11, 0, 0, 0))

    @pytest.mark.skip_coverage
    @given(oracleRate=impliedRateStrategy)
    def test_risk_adjusted_pv(self, assetLibrary, cashGroups, oracleRate):
        # has a 30 bps buffer / haircut
        (cashGroup, _) = cashGroups[0]

        # the longer dated the maturity, the lower the pv holding everything else constant
        maturities = [START_TIME + (90 * SECONDS_IN_DAY) * i for i in range(1, 50, 3)]
        prevPositivePV = 1e18
        prevNegativePV = -1e18
        for m in maturities:
            riskPVPositive = assetLibrary.getRiskAdjustedPresentValue(
                cashGroup, 1e18, m, START_TIME, oracleRate
            )
            pvPositive = assetLibrary.getPresentValue(1e18, m, START_TIME, oracleRate)

            assert pvPositive > riskPVPositive
            assert riskPVPositive < prevPositivePV or riskPVPositive == 0
            prevPositivePV = riskPVPositive

            # further away then you can hold less capital against it
            riskPVNegative = assetLibrary.getRiskAdjustedPresentValue(
                cashGroup, -1e18, m, START_TIME, oracleRate
            )
            pvNegative = assetLibrary.getPresentValue(-1e18, m, START_TIME, oracleRate)

            assert pvNegative > riskPVNegative
            assert prevNegativePV < riskPVNegative or riskPVNegative == -1e18
            prevNegativePV = riskPVNegative

    def test_floor_discount_rate(self, assetLibrary, cashGroups):
        cashGroup = cashGroups[0][0]
        riskPVNegative = assetLibrary.getRiskAdjustedPresentValue(
            cashGroup, -1e18, MARKETS[0], START_TIME, 1
        )
        assert riskPVNegative == -1e18

    def test_oracle_rate_failure(self, assetLibrary, cashGroups):
        assets = [get_fcash_token(1, maturity=MARKETS[5])]

        # Fails due to unset market
        with brownie.reverts():
            assetLibrary.getNetCashGroupValue(assets, START_TIME, 0)

    @given(randSeed=strategy("uint"))
    def test_portfolio_value(self, assetLibrary, cashGroups, randSeed):
        cgs = [cashGroups[0][0], cashGroups[1][0], cashGroups[2][0]]
        assets = get_portfolio_array(5, cgs, sorted=True, noLiquidity=True)

        primeValuesRiskAdjusted = []
        i = 0
        for c in cgs:
            (av, i) = assetLibrary.getNetCashGroupValue(assets, START_TIME, i)
            primeValuesRiskAdjusted.append(av)

        assert len(primeValuesRiskAdjusted) == 3
        assert i == len(assets)

        totalPrimeValue = [0, 0, 0]
        for (i, asset) in enumerate(assets):
            currencyId = asset[0]
            (pr, _) = assetLibrary.buildPrimeRateView(currencyId, START_TIME)

            market = assetLibrary.getMarket(currencyId, asset[1], SETTLEMENT_DATE)
            totalPrimeValue[currencyId - 1] += assetLibrary.convertFromUnderlying(
                pr,
                assetLibrary.getPresentValue(asset[3], asset[1], START_TIME, market["oracleRate"]),
            )

        for (i, pv) in enumerate(totalPrimeValue):
            if pv == 0:
                assert primeValuesRiskAdjusted[i] == 0
            else:
                assert pv > primeValuesRiskAdjusted[i]
