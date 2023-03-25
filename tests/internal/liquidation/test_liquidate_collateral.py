import logging
import random

import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    get_expected,
    move_collateral_exchange_rate,
    setup_collateral_liquidation,
)

LOGGER = logging.getLogger(__name__)
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
        self,
        MockCollateralLiquidation,
        SettleAssetsExternal,
        FreeCollateralExternal,
        FreeCollateralAtTime,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        FreeCollateralAtTime.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockCollateralLiquidation)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @given(
        local=strategy("uint", min_value=1, max_value=4),
        localDebt=strategy("int", min_value=-100_000e8, max_value=-1e8),
        ratio=strategy("uint", min_value=5, max_value=150),
        balanceShare=strategy("uint", min_value=0, max_value=100),
        acceptNToken=strategy("bool"),
    )
    def test_liquidate_cash_and_ntokens(
        self, liquidation, accounts, local, localDebt, ratio, balanceShare, acceptNToken
    ):
        blockTime = chain.time()

        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt, blockTime)

        # Get the collateral required for the liquidation
        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )
        collateralAssetRequired = liquidation.calculate_from_underlying(
            collateral, collateralUnderlying, blockTime
        )

        # Splits the required cash between cash and nTokens. Use the haircut nToken value to
        # determine the nToken balance so that the collateral value sums properly
        collateralCashAsset = Wei(collateralAssetRequired * balanceShare / 100)
        nTokenAssetHaircut = collateralAssetRequired * (100 - balanceShare) / 100
        nTokenBalance = liquidation.calculate_ntoken_from_asset(
            collateral, nTokenAssetHaircut, blockTime, valueType="haircut"
        )

        liquidation.mock.setBalance(accounts[0], collateral, collateralCashAsset, nTokenBalance)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)

        # There should be a FC ~ 0 at this point accounting for the fcDiff due to LTs
        (fc, _) = liquidation.mock.getFreeCollateralAtTime(accounts[0], chain.time() + 1)
        assert pytest.approx(fc, rel=1e-6, abs=0.01e8) == 0

        # Moves the exchange rate based on the ratio
        (newExchangeRate, discountedExchangeRate) = move_collateral_exchange_rate(
            liquidation, local, collateral, ratio
        )

        # FC is be negative at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateralAtTime(accounts[0], chain.time() + 1)
        collateralAvailable = netLocal[1 if collateral > local else 0]

        (
            expectedCollateralTrade,
            collateralETHHaircutValue,
            debtETHBufferValue,
            collateralToSell,
            collateralDenominatedFC,
        ) = get_expected(
            liquidation,
            local,
            collateral,
            newExchangeRate,
            discountedExchangeRate,
            liquidation.calculate_to_underlying(collateral, collateralAvailable, blockTime),
            fc,
        )

        # Convert to asset cash
        expectedCollateralTradeAsset = liquidation.calculate_from_underlying(
            collateral, expectedCollateralTrade
        )

        txn = liquidation.mock.calculateCollateralCurrencyTokens(
            accounts[0], local, collateral, 0, 0 if acceptNToken else 1, {"from": accounts[1]}
        )

        (
            localAssetCashFromLiquidator,
            collateralAssetCashToLiquidator,
            nTokensPurchased,
            netCashWithdrawn,
            portfolio,
        ) = txn.events["CollateralLiquidationTokens"][0].values()

        totalCollateralValueToLiquidator = (
            collateralAssetCashToLiquidator
            + liquidation.calculate_ntoken_to_asset(
                collateral, nTokensPurchased, chain.time(), valueType="liquidator"
            )
        )

        assert (
            pytest.approx(expectedCollateralTradeAsset, rel=1e-2)
            == totalCollateralValueToLiquidator
        )

        # IN UNDERLYING #
        # Check that the price is correct (underlying)
        collateralCashFinal = liquidation.calculate_to_underlying(
            collateral, totalCollateralValueToLiquidator, blockTime
        )
        localCashFinal = liquidation.calculate_to_underlying(
            local, localAssetCashFromLiquidator, blockTime
        )
        assert (
            pytest.approx((localCashFinal * discountedExchangeRate) / 1e18, rel=1e-6)
            == collateralCashFinal
        )
        # END UNDERLYING #
        # ASSET VALUES
        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )

        assert (nTokenBalance - nTokensPurchased) >= 0
        # This value is disabled now
        assert netCashWithdrawn == 0
        liquidation.mock.setBalance(
            accounts[0],
            collateral,
            # Can liquidate to negative cash balances
            collateralCashAsset - collateralAssetCashToLiquidator + netCashWithdrawn,
            nTokenBalance - nTokensPurchased,
        )
        # ASSET VALUES

        blockTime = chain.time() + 1
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)
        collateralAvailable = netLocalAfter[1 if collateral > local else 0]
        localAvailable = netLocalAfter[0 if collateral > local else 1]
        assert collateralAvailable >= 0
        assert localAvailable <= 0

        collateralETHHaircutDiff = 0
        if nTokensPurchased > 0:
            # The nToken haircut is split between a discount given to the liquidator,
            # and a collateral benefit given to the liquidated account
            liquidate = liquidation.calculate_ntoken_to_asset(
                collateral, nTokensPurchased, blockTime, "liquidator"
            )
            haircut = liquidation.calculate_ntoken_to_asset(
                collateral, nTokensPurchased, blockTime, "haircut"
            )
            collateralDiff = liquidation.calculate_to_underlying(
                collateral, liquidate - haircut, blockTime
            )

            if collateral == 1:
                collateralETHHaircutDiff = liquidation.calculate_to_eth(collateral, collateralDiff)
            else:
                collateralETHHaircutDiff = liquidation.calculate_to_eth(
                    collateral, collateralDiff, rate=newExchangeRate
                )

        finalExpectedFC = (
            fc - collateralETHHaircutValue - debtETHBufferValue + collateralETHHaircutDiff
        )
        assert pytest.approx(finalExpectedFC, rel=1e-6, abs=100) == fcAfter
        assert fcAfter > fc

    @given(
        local=strategy("uint", min_value=1, max_value=4),
        maxCollateralLiquidation=strategy("uint", min_value=10, max_value=100),
        maxNTokenBalance=strategy("uint", min_value=5, max_value=100),
    )
    def test_liquidate_limits(
        self, liquidation, accounts, local, maxCollateralLiquidation, maxNTokenBalance
    ):
        blockTime = chain.time()

        # Set the local debt amount
        localDebt = -10_000e8
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt, blockTime)

        # Get the collateral required for the liquidation
        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )
        collateralAssetRequired = liquidation.calculate_from_underlying(
            collateral, collateralUnderlying, blockTime
        )

        # Splits the required cash between cash and nTokens. Use the haircut nToken value to
        # determine the nToken balance so that the collateral value sums properly
        collateralCashAsset = Wei(collateralAssetRequired / 2)
        nTokenAssetHaircut = Wei(collateralAssetRequired / 2)
        nTokenBalance = liquidation.calculate_ntoken_from_asset(
            collateral, nTokenAssetHaircut, blockTime, valueType="haircut"
        )

        liquidation.mock.setBalance(accounts[0], collateral, collateralCashAsset, nTokenBalance)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)
        (_, discountedExchangeRate) = move_collateral_exchange_rate(
            liquidation, local, collateral, 10
        )

        maxCollateral = collateralAssetRequired * maxCollateralLiquidation / 100
        maxNToken = nTokenBalance * maxNTokenBalance / 100

        (fcBefore, _) = liquidation.mock.getFreeCollateralAtTime(accounts[0], chain.time() + 1)

        txn = liquidation.mock.calculateCollateralCurrencyTokens(
            accounts[0], local, collateral, maxCollateral, maxNToken, {"from": accounts[1]}
        )

        (
            localAssetCashFromLiquidator,
            collateralAssetCashToLiquidator,
            nTokensPurchased,
            _,
            _,
        ) = txn.events["CollateralLiquidationTokens"][0].values()

        assert (nTokenBalance - nTokensPurchased) >= 0
        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )
        liquidation.mock.setBalance(
            accounts[0],
            collateral,
            # Can liquidate to negative cash balances
            collateralCashAsset - collateralAssetCashToLiquidator,
            nTokenBalance - nTokensPurchased,
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateralAtTime(
            accounts[0], chain.time() + 1
        )
        collateralAvailable = netLocalAfter[1 if collateral > local else 0]
        localAvailable = netLocalAfter[0 if collateral > local else 1]
        assert collateralAvailable >= 0
        assert localAvailable <= 0
        assert fcAfter > fcBefore

        # Check that boundaries are respected

        assert nTokensPurchased <= maxNToken
        totalCollateralValueToLiquidator = (
            collateralAssetCashToLiquidator
            + liquidation.calculate_ntoken_to_asset(
                collateral, nTokensPurchased, chain.time(), valueType="liquidator"
            )
        )
        assert totalCollateralValueToLiquidator <= maxCollateral

        # Assert that the cash paid by the liquidator is correct
        collateralCashFinal = liquidation.calculate_to_underlying(
            collateral, totalCollateralValueToLiquidator, blockTime
        )
        localCashFinal = liquidation.calculate_to_underlying(
            local, localAssetCashFromLiquidator, blockTime
        )
        assert (
            pytest.approx((localCashFinal * discountedExchangeRate) / 1e18, rel=1e-6)
            == collateralCashFinal
        )
