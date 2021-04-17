import pytest
from brownie.network.state import Chain
from tests.constants import START_TIME
from tests.helpers import get_balance_state, get_cash_group_with_max_markets, get_eth_rate_mapping

chain = Chain()

EMPTY_PORTFOLIO_STATE = ([], [], 0, 0)


@pytest.mark.liquidation
class TestLiquidateLocalNTokens:
    @pytest.fixture(scope="module", autouse=True)
    def ethAggregators(self, MockAggregator, accounts):
        return [
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
        ]

    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self,
        MockLocalLiquidationOverride,
        MockLiquidationSetup,
        SettleAssetsExternal,
        FreeCollateralExternal,
        MockCToken,
        cTokenAggregator,
        ethAggregators,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})

        liquidateOverride = accounts[0].deploy(MockLocalLiquidationOverride)
        liquidateSetup = accounts[0].deploy(MockLiquidationSetup)
        ctoken = accounts[0].deploy(MockCToken, 8)
        # This is the identity rate
        ctoken.setAnswer(1e18)
        aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

        rateStorage = (aggregator.address, 8)
        ethAggregators[0].setAnswer(1e18)
        cg = get_cash_group_with_max_markets(3)
        liquidateOverride.setAssetRateMapping(1, rateStorage)
        liquidateSetup.setAssetRateMapping(1, rateStorage)
        liquidateOverride.setCashGroup(1, cg)
        liquidateSetup.setCashGroup(1, cg)
        liquidateOverride.setETHRateMapping(
            1, get_eth_rate_mapping(ethAggregators[0], discount=104)
        )
        liquidateSetup.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0], discount=104))

        chain.mine(1, timestamp=START_TIME)

        return (liquidateOverride, liquidateSetup)

    def test_liquidate_ntoken_no_limit(self, liquidation, accounts):
        (liquidateOverride, liquidateSetup) = liquidation
        (cashGroup, markets) = liquidateOverride.buildCashGroupView(1)

        factors = (
            accounts[0],
            -100e8,
            100e8,
            0,
            990e8,
            "0x5F00005A0000",  # 95 liquidation, 90 haircut
            (1e18, 1e18, 140, 100, 106),
            (0, 0, 0, 0, 0),
            cashGroup,
            markets,
        )

        (
            balanceState,
            netLocalFromLiquidator,
            markets,
        ) = liquidateOverride.liquidateLocalCurrencyOverride(
            1,
            0,
            START_TIME,
            get_balance_state(1, storedCashBalance=-100e8, storedNTokenBalance=1100e8),
            factors,
        )

        # allowed to purchase up to 40% of 1100
        assert balanceState[5] == -440e8
        assert netLocalFromLiquidator == (440e8 * 0.95)

    def test_liquidate_ntoken_more_than_limit(self, liquidation, accounts):
        (liquidateOverride, liquidateSetup) = liquidation
        (cashGroup, markets) = liquidateOverride.buildCashGroupView(1)

        factors = (
            accounts[0],
            -1000000e8,
            100e8,
            0,
            99e8,
            "0x5F00005A0000",  # 95 liquidation, 90 haircut
            (1e18, 1e18, 140, 100, 106),
            (0, 0, 0, 0, 0),
            cashGroup,
            markets,
        )

        (
            balanceState,
            netLocalFromLiquidator,
            markets,
        ) = liquidateOverride.liquidateLocalCurrencyOverride(
            1,
            0,
            START_TIME,
            get_balance_state(1, storedCashBalance=-100e8, storedNTokenBalance=110e8),
            factors,
        )

        # allowed to purchase up to 100% of 110
        assert balanceState[5] == -110e8
        assert netLocalFromLiquidator == (110e8 * 0.95)

    def test_liquidate_ntoken_limit_to_user_specification(self, liquidation, accounts):
        (liquidateOverride, liquidateSetup) = liquidation
        (cashGroup, markets) = liquidateOverride.buildCashGroupView(1)

        factors = (
            accounts[0],
            -1000000e8,
            100e8,
            0,
            99e8,
            "0x5F00005A0000",  # 95 liquidation, 90 haircut
            (1e18, 1e18, 140, 100, 106),
            (0, 0, 0, 0, 0),
            cashGroup,
            markets,
        )

        (
            balanceState,
            netLocalFromLiquidator,
            markets,
        ) = liquidateOverride.liquidateLocalCurrencyOverride(
            1,
            10e8,
            START_TIME,
            get_balance_state(1, storedCashBalance=-100e8, storedNTokenBalance=110e8),
            factors,
        )

        # allowed to purchase up to 100% of 110
        assert balanceState[5] == -10e8
        assert netLocalFromLiquidator == (10e8 * 0.95)
