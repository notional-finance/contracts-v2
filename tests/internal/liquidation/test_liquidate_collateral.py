import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    get_expected,
    move_collateral_exchange_rate,
    setup_collateral_liquidation,
)

chain = Chain()

"""
Liquidate Collateral Test Matrix

Invariants:
    - FC increases
    - No balances go negative

1. Only Cash
    => calculateLiquidationAmount test
    => balance >= amount
    => balance < amount

2. Only Liquidity Token
    => Markets only update during non calculation
    => cashClaim >= amount
    => cashClaim < amount

3. Only nToken
    => nTokenValue >= amount
    => nTokenValue < amount
    => maxNTokenAmount >= amount, nTokenValue >= amount
    => maxNTokenAmount >= amount, nTokenValue < amount
    => maxNTokenAmount < amount, nTokenValue >= amount
    => maxNTokenAmount < amount, nTokenValue < amount

4. Cash + Liquidity Token
    => balance >= amount, cashClaim ?
    => balance < amount, cashClaim > amount
    => balance < amount, cashClaim < amount

5. Cash + nToken
    => balance >= amount, nTokenValue ?
    => balance < amount, nTokenValue > amount
    => balance < amount, nTokenValue < amount

6. Cash + Liquidity Token + nToken
    => balance >= amount, cashClaim ?, nTokenValue ?
    => balance < amount, cashClaim > amount, nTokenValue ?
    => balance < amount, cashClaim < amount, nTokenValue > amount
    => balance < amount, cashClaim < amount, nTokenValue < amount

7. Liquidity Token + nToken
    => cashClaim >= amount, nTokenValue ?
    => cashClaim < amount, nTokenValue > amount
    => cashClaim < amount, nTokenValue < amount

# For each liquidation:
1. calculate the local benefit
2. validate the liquidator amounts
3. validate the fc afterwards
"""


@pytest.mark.liquidation
class TestLiquidateCollateral:
    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self, MockCollateralLiquidation, SettleAssetsExternal, FreeCollateralExternal, accounts
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockCollateralLiquidation)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @pytest.mark.only
    @given(
        local=strategy("uint", min_value=1, max_value=4),
        localDebt=strategy("int", min_value=-100_000e8, max_value=-1e8),
        ratio=strategy("uint", min_value=5, max_value=150),
    )
    def test_liquidate_cash(self, liquidation, accounts, local, localDebt, ratio):
        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)

        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )

        # Set the asset cash balance
        collateralCashAsset = liquidation.calculate_from_underlying(
            collateral, collateralUnderlying
        )
        liquidation.mock.setBalance(accounts[0], collateral, collateralCashAsset, 0)

        # There should be a FC ~ 0 at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])
        assert pytest.approx(fc, abs=100) == 0

        # Moves the exchange rate based on the ratio
        (newExchangeRate, discountedExchangeRate) = move_collateral_exchange_rate(
            liquidation, local, collateral, ratio
        )

        # FC is be negative at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        (expectedCollateralTrade, expectedNetETHBenefit) = get_expected(
            liquidation,
            local,
            collateral,
            newExchangeRate,
            discountedExchangeRate,
            collateralUnderlying,
            fc,
        )

        # Convert to asset cash
        expectedCollateralTradeAsset = liquidation.calculate_from_underlying(
            collateral, expectedCollateralTrade
        )

        (
            localAssetCashFromLiquidator,
            collateralAssetCashToLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateCollateralCurrencyLiquidation.call(
            accounts[0], local, collateral, 0, 0, {"from": accounts[1]}
        )
        assert (
            pytest.approx(collateralAssetCashToLiquidator, abs=100) == expectedCollateralTradeAsset
        )
        assert nTokensPurchased == 0

        # IN UNDERLYING #
        # Check that the price is correct (underlying)
        collateralCashFinal = liquidation.calculate_to_underlying(
            collateral, collateralAssetCashToLiquidator
        )
        localCashFinal = liquidation.calculate_to_underlying(local, localAssetCashFromLiquidator)
        assert (
            pytest.approx((localCashFinal * discountedExchangeRate) / 1e18, rel=1e-6)
            == collateralCashFinal
        )
        # END UNDERLYING #

        # ASSET VALUES
        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )
        liquidation.mock.setBalance(
            accounts[0], collateral, collateralCashAsset - collateralAssetCashToLiquidator, 0
        )
        # ASSET VALUES

        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0])
        # This is in underlying
        assert pytest.approx(fc - expectedNetETHBenefit, abs=100) == fcAfter
