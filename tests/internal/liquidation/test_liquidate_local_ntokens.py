import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.internal.liquidation.liquidation_helpers import ValuationMock

chain = Chain()

EMPTY_PORTFOLIO_STATE = ([], [], 0, 0)
"""
Liquidate Local Currency Test Matrix:

1. Only nToken
    => calculateLiquidationAmount test
    => nTokensToLiquidateHaircutValue > netAssetCashFromLiquidator
2. Only Liquidity Token
    => Markets Update in actual
    => Markets don't update in calculate
    => Portfolio updates in actual
    => incentive is paid to liquidator
    => cash removed and fCash removed nets off
3. Both
    => assetBenefitRequired falls through from liquidity token to nToken
    => netAssetCashFromLiquidator is the net of the incentive paid and the nTokenLiquidateValue
"""


@pytest.mark.liquidation
class TestLiquidateLocalNTokens:
    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self, MockLocalLiquidation, SettleAssetsExternal, FreeCollateralExternal, accounts
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockLocalLiquidation)

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_negative_local_available(
        self, liquidation, accounts, currency, nTokenBalance, ratio
    ):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "liquidator")
        benefit = liquidator - haircut

        # if cashBalance < -haircut then under fc
        # if cashBalance < -liquidator then insolvent
        # ratio of 100 == liquidator, ratio > 100 is insolvent
        cashBalance = -Wei(haircut + (benefit * ratio * 1e8) / 1e10)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, nTokenBalance)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, 0, {"from": accounts[1]}
        )
        # Check that the price returned is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, "liquidator")
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        # Simulate the transfer above and check the FC afterwards
        liquidation.mock.setBalance(
            accounts[0],
            currency,
            cashBalance + localAssetCashFromLiquidator,
            nTokenBalance - nTokensPurchased,
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0])

        if ratio <= 40:
            # In the case that the ratio is less than 40%, we liquidate up to 40%
            assert pytest.approx(Wei(netLocal[0] + benefit * 0.40), abs=5) == netLocalAfter[0]
            assert fcAfter > 0
        elif ratio > 100:
            # In this scenario we liquidate all the nTokens and are still undercollateralized
            assert nTokenBalance == nTokensPurchased
            assert pytest.approx(Wei(netLocal[0] + benefit), abs=5) == netLocalAfter[0]
            assert fcAfter < 0
        else:
            # In each of these scenarios sufficient nTokens exist to liquidate to zero fc,
            # some dust will exist when rounding this back to zero, we may undershoot due to
            # truncation in solidity math
            assert -1e5 <= netLocalAfter[0] and netLocalAfter[0] <= 0
            assert -100 <= fcAfter and fcAfter <= 0

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        nTokenLimit=strategy("uint", min_value=1, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    @pytest.mark.only
    def test_ntoken_negative_local_available_user_limit(
        self, liquidation, accounts, currency, nTokenBalance, ratio, nTokenLimit
    ):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "liquidator")
        benefit = liquidator - haircut

        # if cashBalance < -haircut then under fc
        # if cashBalance < -liquidator then insolvent
        # ratio of 100 == liquidator, ratio > 100 is insolvent
        cashBalance = -Wei(haircut + (benefit * ratio * 1e8) / 1e10)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, nTokenBalance)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, nTokenLimit, {"from": accounts[1]}
        )

        assert nTokensPurchased <= nTokenLimit
        # Check that the price returned is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, "liquidator")

    def test_ntoken_positive_local_available():
        pass

    def test_ntoken_positive_local_available_user_limit():
        pass

    @pytest.mark.todo
    def test_ntoken_local_no_currency():
        pass
