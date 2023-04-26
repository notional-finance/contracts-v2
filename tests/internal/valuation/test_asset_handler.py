import math

import brownie
import pytest
from brownie.network.contract import Contract
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import (
    BASIS_POINT,
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
    get_market_state,
    get_portfolio_array,
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


    def test_oracle_rates_below_minimum(self, assetLibrary):
        settings = get_cash_group_with_max_markets(3)
        settings[6] = 5 # 1.25% min oracle rate
        settings[5] = 2 # 0.01
        settings[7] = 1 # liquidation haircut must be less than
        assetLibrary.setCashGroup(1, settings)

        # All are below the min oracle rate with the haircut added
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[0], lastImpliedRate=0.002e9, oracleRate=0.002e9))
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[1], lastImpliedRate=0.012e9, oracleRate=0.012e9))
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[2], lastImpliedRate=0.027e9, oracleRate=0.027e9))

        # All maturities out to one year, counting by 30, ensures that market maturities are hit
        maturities = [START_TIME_TREF + SECONDS_IN_DAY * i for i in range(30, 360, 30)]
        for m in maturities:
            (oracleRate, fCashOracleRate, _) = assetLibrary.getOracleRates(1, m, START_TIME_TREF, 0)
            # fcash oracle rates are always higher than the actual oracle rate
            assert oracleRate < fCashOracleRate
            assert fCashOracleRate == max(0.0125e9, fCashOracleRate)


    def test_oracle_rates_above_maximum(self, assetLibrary):
        settings = get_cash_group_with_max_markets(3)
        settings[4] = 2 # 0.01
        settings[8] = 1 # liquidation haircut must be less than
        settings[9] = 75 # 18.75%
        assetLibrary.setCashGroup(1, settings)

        # All are above the max oracle rate with the buffer subtracted
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[0], lastImpliedRate=0.17e9, oracleRate=0.17e9))
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[1], lastImpliedRate=0.20e9, oracleRate=0.20e9))
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[2], lastImpliedRate=0.25e9, oracleRate=0.25e9))

        # All maturities out to one year, counting by 30, ensures that market maturities are hit
        maturities = [START_TIME_TREF + SECONDS_IN_DAY * i for i in range(30, 360, 30)]
        for m in maturities:
            # Set the block supply rate to 16%
            (oracleRate, _, debtOracleRate) = assetLibrary.getOracleRates(1, m, START_TIME_TREF, 0.16e9)
            # debt oracle rates are always lower than the actual oracle rate
            assert debtOracleRate < oracleRate
            assert debtOracleRate == min(0.1875e9, debtOracleRate)

    def test_oracle_rates_within_boundaries(self, assetLibrary):
        settings = get_cash_group_with_max_markets(3)
        settings[6] = 5 # 1.25%
        settings[9] = 75 # 18.75%
        assetLibrary.setCashGroup(1, settings)

        # All are above the max oracle rate with the buffer subtracted
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[0], lastImpliedRate=0.05e9, oracleRate=0.05e9))
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[1], lastImpliedRate=0.06e9, oracleRate=0.06e9))
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[2], lastImpliedRate=0.07e9, oracleRate=0.07e9))

        # All maturities out to one year, counting by 30, ensures that market maturities are hit
        maturities = [START_TIME_TREF + SECONDS_IN_DAY * i for i in range(30, 360, 30)]
        for m in maturities:
            # Set the block supply rate to 4%
            (oracleRate, fCashOracleRate, debtOracleRate) = assetLibrary.getOracleRates(1, m, START_TIME_TREF, 0.04)
            # Oracle rates do not hit min and max figures
            assert fCashOracleRate == oracleRate + 0.015e9
            assert debtOracleRate == oracleRate - 0.015e9

    @given(maxDiscountFactor=strategy("uint8", min_value=1))
    def test_max_discount_factor(self, assetLibrary, maxDiscountFactor):
        settings = get_cash_group_with_max_markets(3)
        settings[2] = maxDiscountFactor
        assetLibrary.setCashGroup(1, settings)
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[0], lastImpliedRate=0.001e9, oracleRate=0.001e9))

        # Get the one day discount factor
        maturity = START_TIME_TREF + SECONDS_IN_DAY
        (riskPv, pv) = assetLibrary.getRiskAdjustedPresentValue(1, 1e9, maturity, maturity - 10)

        # Discount factor is 1e9
        assert pv == 1e9
        assert riskPv < pv
        assert riskPv == 1e9 - maxDiscountFactor * 5 * BASIS_POINT

    def test_floor_discount_rate(self, assetLibrary):
        assetLibrary.setMarket(1, SETTLEMENT_DATE, get_market_state(MARKETS[0], lastImpliedRate=0.001e9, oracleRate=0.001e9))
        (riskPv, pv) = assetLibrary.getRiskAdjustedPresentValue(
            1, -1e9, MARKETS[0], START_TIME
        )
        assert riskPv == -1e9
        assert riskPv < pv

    def test_oracle_rate_failure(self, assetLibrary):
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
