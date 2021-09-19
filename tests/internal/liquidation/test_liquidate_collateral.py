import random

import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.internal.liquidation.liquidation_helpers import ValuationMock

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
        collateral = random.choice([c for c in range(1, 5) if c != local])
        localBuffer = liquidation.bufferHaircutDiscount[local][0]
        collateralHaircut = liquidation.bufferHaircutDiscount[collateral][1]

        # This test needs to work off of changes to exchange rates, set up first such that
        # we have collateral and local in alignment at zero free collateral
        netETHRequired = liquidation.calculate_to_eth(local, localDebt)
        collateralUnderlying = Wei(
            liquidation.calculate_from_eth(collateral, -netETHRequired) * 100 / collateralHaircut
        )

        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt)
        collateralCashAsset = liquidation.calculate_from_underlying(
            collateral, collateralUnderlying
        )
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)
        liquidation.mock.setBalance(accounts[0], collateral, collateralCashAsset, 0)

        # There should be a FC ~ 0 at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])
        assert pytest.approx(fc, abs=100) == 0

        # Now we change the exchange rates to simulate undercollateralization, decreasing
        # the exchange rate will also decrease the FC
        # Exchange Rates can move by by a maximum of (1 / buffer) * haircut, this is insolvency
        # If ratio > 100 then we are insolvent
        # If ratio == 0 then fc is 0
        maxPercentDecrease = (1 / localBuffer) * collateralHaircut
        exchangeRateDecrease = 100 - ((ratio * maxPercentDecrease) / 100)
        liquidationDiscount = liquidation.get_discount(local, collateral)

        if collateral != 1:
            newExchangeRate = liquidation.ethRates[collateral] * exchangeRateDecrease / 100
            liquidation.ethAggregators[collateral].setAnswer(newExchangeRate)
            discountedExchangeRate = (
                ((liquidation.ethRates[local] * 1e18) / newExchangeRate) * liquidationDiscount / 100
            )
        else:
            # The collateral currency is ETH so we have to change the local currency
            # exchange rate instead
            newExchangeRate = liquidation.ethRates[local] * 100 / exchangeRateDecrease
            liquidation.ethAggregators[local].setAnswer(newExchangeRate)
            discountedExchangeRate = (
                ((newExchangeRate * 1e18) / liquidation.ethRates[collateral])
                * liquidationDiscount
                / 100
            )

        # FC is be negative at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        # Convert the free collateral amount back to the collateral currency at the
        # new exchange rate
        if collateral == 1:
            # In this case it is ETH
            fcInCollateral = -fc
        else:
            fcInCollateral = liquidation.calculate_from_eth(collateral, -fc, rate=newExchangeRate)

        # Apply the default liquidation buffer and cap at the total balance
        if fcInCollateral < collateralUnderlying * 0.4:
            expectedCollateralTrade = collateralUnderlying * 0.4
        else:
            # Cannot go above the total balance
            expectedCollateralTrade = min(collateralUnderlying, fcInCollateral)

        expectedLocalCash = Wei(expectedCollateralTrade * 1e18 / discountedExchangeRate)

        # Apply haircuts and buffers
        if collateral == 1:
            # This is the reduction in the net ETH figure as a result of trading away this
            # amount of collateral
            collateralETHHaircutValue = liquidation.calculate_to_eth(
                collateral, expectedCollateralTrade
            )
            # This is the benefit to the haircut position
            debtETHBufferValue = liquidation.calculate_to_eth(
                local, -expectedLocalCash, rate=newExchangeRate
            )
        else:
            collateralETHHaircutValue = liquidation.calculate_to_eth(
                collateral, expectedCollateralTrade, rate=newExchangeRate
            )
            debtETHBufferValue = liquidation.calculate_to_eth(local, -expectedLocalCash)

        # Total benefit is:
        expectedNetETHBenefit = collateralETHHaircutValue + debtETHBufferValue
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
