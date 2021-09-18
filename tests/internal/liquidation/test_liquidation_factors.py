import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_DAY, START_TIME_TREF
from tests.helpers import get_fcash_token
from tests.internal.liquidation.liquidation_helpers import ValuationMock

chain = Chain()


@pytest.mark.liquidation
class TestLiquidationFactors:
    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self, MockLiquidationSetup, SettleAssetsExternal, FreeCollateralExternal, accounts
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockLiquidationSetup)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_cannot_liquidate_self(self, liquidation, accounts):
        mock = liquidation.mock
        mock.setBalance(accounts[1], 1, -100e8, 0)

        with brownie.reverts():
            mock.preLiquidationActions(accounts[0], 1, 2)

    def test_revert_on_sufficient_collateral(self, liquidation, accounts):
        mock = liquidation.mock
        mock.setBalance(accounts[1], 1, 100e8, 0)
        mock.setBalance(accounts[1], 2, 100e8, 0)

        with brownie.reverts("Sufficient collateral"):
            mock.preLiquidationActions(accounts[1], 1, 2)
            mock.preLiquidationActions(accounts[1], 2, 1)
            mock.preLiquidationActions(accounts[1], 1, 0)
            mock.preLiquidationActions(accounts[1], 2, 0)

    def test_revert_on_sufficient_portfolio_value(self, liquidation, accounts):
        mock = liquidation.mock
        mock.setPortfolio(accounts[1], [get_fcash_token(1, notional=100e8)])
        mock.setBalance(accounts[1], 2, 100e8, 0)

        with brownie.reverts("Sufficient collateral"):
            mock.preLiquidationActions(accounts[1], 1, 0)
            mock.preLiquidationActions(accounts[1], 1, 2)

    def test_revert_on_sufficient_bitmap_value(self, liquidation, accounts):
        mock = liquidation.mock
        mock.enableBitmapForAccount(accounts[0], 1, START_TIME_TREF)
        mock.setifCashAsset(accounts[0], 1, START_TIME_TREF + SECONDS_IN_DAY * 30, 100e8)
        mock.setBalance(accounts[0], 2, 100e8, 200e8)

        with brownie.reverts("Sufficient collateral"):
            mock.preLiquidationActions(accounts[1], 1, 0)
            mock.preLiquidationActions(accounts[1], 1, 2)

    def test_revert_on_invalid_currencies(self, liquidation, accounts):
        mock = liquidation.mock
        mock.enableBitmapForAccount(accounts[0], 1, START_TIME_TREF)

        with brownie.reverts():
            # Equal currency ids
            mock.preLiquidationActions(accounts[1], 1, 1)
            # Local cannot be zero
            mock.preLiquidationActions(accounts[1], 0, 1)
            # For bitmap, local must be bitmap
            mock.preLiquidationActions(accounts[0], 2, 0)
            mock.preLiquidationActions(accounts[0], 2, 2)

    @given(
        liquidateAmountRequired=strategy("uint", min_value=0, max_value=100_000_000e8),
        maxTotalBalance=strategy("uint", min_value=0, max_value=100_000_000e8),
        userSpecifiedMaximum=strategy("uint", min_value=1, max_value=100_000_000e8),
    )
    def test_liquidation_amount(
        self, liquidation, liquidateAmountRequired, maxTotalBalance, userSpecifiedMaximum
    ):
        amount = liquidation.mock.calculateLiquidationAmount(
            liquidateAmountRequired, maxTotalBalance, 0
        )
        if liquidateAmountRequired > maxTotalBalance * 0.40:
            if liquidateAmountRequired <= maxTotalBalance:
                assert amount == liquidateAmountRequired
            else:
                assert amount <= maxTotalBalance
        else:
            assert pytest.approx(amount, abs=1) == Wei(maxTotalBalance * 0.40)

        amount = liquidation.mock.calculateLiquidationAmount(
            liquidateAmountRequired, maxTotalBalance, userSpecifiedMaximum
        )
        assert amount <= maxTotalBalance
        assert amount <= userSpecifiedMaximum

    @pytest.mark.todo
    def test_cross_currency_benefit(self, liquidation, accounts):
        pass

    @pytest.mark.todo
    def test_local_to_purchase(self, liquidation, accounts):
        pass
