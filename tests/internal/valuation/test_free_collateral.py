import brownie
import pytest
from brownie.network.state import Chain
from tests.constants import (
    HAS_ASSET_DEBT,
    HAS_CASH_DEBT,
    SECONDS_IN_DAY,
    SETTLEMENT_DATE,
    START_TIME,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_market_curve,
)

chain = Chain()


@pytest.mark.valuation
class TestFreeCollateral:
    @pytest.fixture(scope="module", autouse=True)
    def ethAggregators(self, MockAggregator, accounts):
        return [
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
        ]

    @pytest.fixture(scope="module", autouse=True)
    def freeCollateral(
        self,
        MockFreeCollateral,
        SettleAssetsExternal,
        MockCToken,
        cTokenAggregator,
        FreeCollateralExternal,
        ethAggregators,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        fc = accounts[0].deploy(MockFreeCollateral)
        ctoken = accounts[0].deploy(MockCToken, 8)
        # This is the identity rate
        ctoken.setAnswer(1e18)
        aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

        rateStorage = (aggregator.address, 8)
        fc.setAssetRateMapping(1, rateStorage)
        cg = get_cash_group_with_max_markets(3)
        fc.setCashGroup(1, cg)
        ethAggregators[0].setAnswer(1e18)
        fc.setETHRateMapping(1, get_eth_rate_mapping(ethAggregators[0]))

        fc.setAssetRateMapping(2, rateStorage)
        fc.setCashGroup(2, cg)
        ethAggregators[1].setAnswer(1e18)
        fc.setETHRateMapping(2, get_eth_rate_mapping(ethAggregators[1], haircut=80))

        fc.setAssetRateMapping(3, rateStorage)
        fc.setCashGroup(3, cg)
        ethAggregators[2].setAnswer(1e18)
        fc.setETHRateMapping(3, get_eth_rate_mapping(ethAggregators[2], haircut=0))

        chain.mine(1, timestamp=START_TIME)

        return fc

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_cash_balance_no_haircut(self, freeCollateral, accounts):
        freeCollateral.setBalance(accounts[0], 1, 100e8, 0)
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc == 100e8

    def test_cash_balance_haircut(self, freeCollateral, accounts):
        freeCollateral.setBalance(accounts[0], 2, 100e8, 0)
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc == 80e8

    def test_cash_balance_full_haircut(self, freeCollateral, accounts):
        freeCollateral.setBalance(accounts[0], 3, 100e8, 0)
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc == 0

    def test_cash_balance_debt(self, freeCollateral, accounts):
        freeCollateral.setBalance(accounts[0], 1, -100e8, 0)
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc == -140e8

    def test_portfolio_fCash_no_haircut(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(1, SETTLEMENT_DATE, m)

        freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, notional=100e8)])
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc > 0 and fc < 100e8

    def test_portfolio_fCash_haircut(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(2, SETTLEMENT_DATE, m)

        freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, currencyId=2, notional=100e8)])
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc > 0 and fc < 80e8

    def test_portfolio_fCash_full_haircut(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(3, SETTLEMENT_DATE, m)

        freeCollateral.setPortfolio(accounts[0], [get_fcash_token(1, currencyId=3, notional=100e8)])
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc == 0

    def test_portfolio_debt(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(3, SETTLEMENT_DATE, m)

        freeCollateral.setPortfolio(
            accounts[0], [get_fcash_token(1, currencyId=3, notional=-100e8)]
        )
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc < 0 and fc > -140e8

    def test_local_collateral_netting(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(3, SETTLEMENT_DATE, m)
        freeCollateral.setPortfolio(
            accounts[0], [get_fcash_token(1, currencyId=3, notional=-105e8)]
        )
        freeCollateral.setBalance(accounts[0], 3, 100e8, 0)
        fc = freeCollateral.getFreeCollateralView(accounts[0])
        assert fc > -5e8 * 1.4

    def test_bitmap_has_debt(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(1, SETTLEMENT_DATE, m)

        freeCollateral.enableBitmapForAccount(accounts[0], 1)
        freeCollateral.setifCashAsset(
            accounts[0], 1, markets[0][1] + SECONDS_IN_DAY * 5, -100e8, START_TIME
        )
        freeCollateral.setifCashAsset(
            accounts[0], 1, markets[0][1] + SECONDS_IN_DAY * 10, 1e8, START_TIME
        )

        with brownie.reverts("Insufficient free collateral"):
            freeCollateral.checkFreeCollateralAndRevert(accounts[0])

        freeCollateral.setBalance(accounts[0], 1, 200e8, 0)
        freeCollateral.checkFreeCollateralAndRevert(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])

        assert context[1] == HAS_ASSET_DEBT

    def test_bitmap_remove_debt(self, freeCollateral, accounts):
        markets = get_market_curve(3, "flat")
        for m in markets:
            freeCollateral.setMarketStorage(1, SETTLEMENT_DATE, m)

        freeCollateral.enableBitmapForAccount(accounts[0], 1)
        freeCollateral.setifCashAsset(
            accounts[0], 1, markets[0][1] + SECONDS_IN_DAY * 5, -100e8, START_TIME
        )
        freeCollateral.setBalance(accounts[0], 1, 200e8, 0)
        freeCollateral.checkFreeCollateralAndRevert(accounts[0])

        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        freeCollateral.setifCashAsset(
            accounts[0], 1, markets[0][1] + SECONDS_IN_DAY * 10, 200e8, START_TIME
        )
        freeCollateral.checkFreeCollateralAndRevert(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        # Net off asset debt
        freeCollateral.setifCashAsset(
            accounts[0], 1, markets[0][1] + SECONDS_IN_DAY * 5, 100e8, START_TIME
        )
        freeCollateral.checkFreeCollateralAndRevert(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == "0x00"  # no debt

    def test_remove_cash_debt(self, freeCollateral, accounts):
        freeCollateral.setBalance(accounts[0], 1, -200e8, 0)
        freeCollateral.setBalance(accounts[0], 2, 400e8, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        # Account still has cash debt, must not change setting
        freeCollateral.checkFreeCollateralAndRevert(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        freeCollateral.setBalance(accounts[0], 1, 0, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        # Cash debt setting is still temporarily on
        assert context[1] == HAS_CASH_DEBT

        freeCollateral.checkFreeCollateralAndRevert(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == "0x00"  # no debt

    # def test_free_collateral_perp_token_value(self, freeCollateral, accounts):
    # def test_free_collateral_combined(self, freeCollateral):
    # def test_free_collateral_multiple_cash_groups()
