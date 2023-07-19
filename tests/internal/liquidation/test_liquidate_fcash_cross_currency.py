import logging
import random

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import get_fcash_token
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    move_collateral_exchange_rate,
    setup_collateral_liquidation,
)

LOGGER = logging.getLogger(__name__)
chain = Chain()

"""
fCash Liquidation Testing Matrix

Test: Bitmap / Array

Need: methods to calculate fCashBeneft and collateralBenefit

Local fCash:
Case: localAssetAvailable > 0
Case: localAssetAvailable <= 0
    - specify positive fCash
        - underlyingBenefitRequired < fCashBenefit
        - underlyingBenefitRequired > fCashBenefit
    - specify negative fCash
        - underlyingBenefitRequired < fCashBenefit
        - underlyingBenefitRequired > fCashBenefit
    - specify both positive and negative fCash
        - underlyingBenefitRequired < fCashBenefit
        - underlyingBenefitRequired > fCashBenefit
        - assert that the cash nets off

Cross Currency fCash, only positive fCash
    - underlyingBenefitRequired < totalBenefit, collateralAsset >= 0
    - underlyingBenefitRequired < totalBenefit, collateralAsset < 0
    - underlyingBenefitRequired >= totalBenefit, collateralAsset >= 0
    - underlyingBenefitRequired >= totalBenefit, collateralAsset < 0
"""


@pytest.mark.liquidation
class TestLiquidatefCash:
    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self,
        MockCrossCurrencyfCashLiquidation,
        SettleAssetsExternal,
        FreeCollateralAtTime,
        FreeCollateralExternal,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        FreeCollateralAtTime.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockCrossCurrencyfCashLiquidation)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @given(
        localDebt=strategy("int", min_value=-100_000e8, max_value=-1e8),
        local=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=10, max_value=150),
        numAssets=strategy("uint", min_value=1, max_value=5),
    )
    def test_cross_currency_fcash(self, liquidation, accounts, localDebt, local, ratio, numAssets):
        blockTime = chain.time()
        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt, blockTime)

        # Gets the collateral fCash asset to set the fc to ~ 0
        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )

        assets = liquidation.get_fcash_portfolio(
            collateral, collateralUnderlying, numAssets, blockTime
        )

        # Set the fCash asset (note: bitmaps cannot have cross currency fCash liquidations)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)
        liquidation.mock.setPortfolio(accounts[0], ([], assets, 0, 0))

        # FC should be ~0 at this point
        (fc1, _) = liquidation.mock.getFreeCollateral(accounts[0], chain.time() + 1)
        assert pytest.approx(fc1, abs=0.55e8) == 0

        # Moves the exchange rate based on the ratio
        (newExchangeRate, discountedExchangeRate) = move_collateral_exchange_rate(
            liquidation, local, collateral, ratio
        )

        # FC is be negative at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0], chain.time() + 1)
        blockTime = chain.time()

        # Convert to expected fCash trade
        maturities = sorted([a[1] for a in assets], reverse=True)
        (
            notionalTransfers,
            localAssetCashFromLiquidator,
        ) = liquidation.mock.calculatefCashCrossCurrencyLiquidation.call(
            accounts[0],
            local,
            collateral,
            maturities,
            [0] * len(maturities),
            blockTime,
            {"from": accounts[1]},
        )

        liquidatorPrice = 0
        fCashHaircut = 0
        state = liquidation.mock.buildPortfolioState(accounts[0])
        for (m, t) in zip(maturities, notionalTransfers):
            matchingfCash = list(filter(lambda x: x[1] == m, assets))[0]
            # Transfer cannot exceed fCash balance.
            assert matchingfCash[3] >= t

            # add transfer to portfolio state
            state = liquidation.mock.addAsset(state, collateral, m, 1, -t)
            liquidator = liquidation.discount_to_pv(collateral, t, m, blockTime, "liquidator")
            haircut = liquidation.discount_to_pv(collateral, t, m, blockTime, "haircut")

            liquidatorPrice += liquidator
            fCashHaircut += haircut

        # Check price is correct
        localCashFinal = liquidation.calculate_to_underlying(
            local, localAssetCashFromLiquidator, blockTime
        )
        assert (
            pytest.approx(Wei((localCashFinal * discountedExchangeRate) / 1e18), rel=1e-4, abs=10)
            == liquidatorPrice
        )

        # Simulate transfer
        liquidation.mock.setPortfolio(accounts[0], state)
        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0], chain.time() + 1)
        blockTime = chain.time()

        # Check that we did not cross available boundaries in the trade
        collateralAvailableBefore = netLocal[1 if collateral > local else 0]
        collateralAvailableAfter = netLocalAfter[1 if collateral > local else 0]
        assert pytest.approx(
            Wei(fCashHaircut), rel=1e-6, abs=100
        ) == liquidation.calculate_to_underlying(
            collateral, collateralAvailableBefore - collateralAvailableAfter, blockTime
        )
        assert collateralAvailableAfter >= 0

        localAvailable = netLocalAfter[0 if collateral > local else 1]
        assert localAvailable <= 0

        # We calculate the difference in fc by looking at the fCashHaircut and the localCash traded
        # rather than using the get_expected method as we do in collateral currency. The reason is
        # that the default liquidation portion is not always applied due to how fCash notionals are
        # distributed
        if collateral == 1:
            debtETHBuffer = liquidation.calculate_to_eth(
                local, -localCashFinal, rate=newExchangeRate
            )
            collateralETHValue = liquidation.calculate_to_eth(collateral, fCashHaircut)
        else:
            debtETHBuffer = liquidation.calculate_to_eth(local, -localCashFinal)
            collateralETHValue = liquidation.calculate_to_eth(
                collateral, fCashHaircut, rate=newExchangeRate
            )

        finalExpectedFC = fc - collateralETHValue - debtETHBuffer

        # fCash haircut is used to determine the amount of collateral traded
        assert pytest.approx(finalExpectedFC, rel=1e-6, abs=5_000) == fcAfter
        assert fcAfter > fc

    @given(numAssets=strategy("uint", min_value=1, max_value=5))
    def test_cross_currency_fcash_user_limit(self, liquidation, accounts, numAssets):
        collateral = 1
        local = 2
        localDebt = -500_000e8
        collateralUnderlying = 10e8
        numAssets = 1
        blockTime = chain.time()

        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)
        assets = liquidation.get_fcash_portfolio(
            collateral, collateralUnderlying, numAssets, blockTime
        )

        # Set the fCash asset (note: bitmaps cannot have cross currency fCash liquidations)
        liquidation.mock.setPortfolio(accounts[0], ([], assets, 0, 0))

        # Convert to expected fCash trade
        maturities = sorted([a[1] for a in assets], reverse=True)
        maxNotionalToTransfer = [Wei(1e8)] * len(maturities)
        (
            notionalTransfers,
            localAssetCashFromLiquidator,
        ) = liquidation.mock.calculatefCashCrossCurrencyLiquidation.call(
            accounts[0],
            local,
            collateral,
            maturities,
            maxNotionalToTransfer,
            blockTime,
            {"from": accounts[1]},
        )

        for (i, n) in enumerate(notionalTransfers):
            assert n <= maxNotionalToTransfer[i]

    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_cross_currency_fcash_no_duplicate_maturities(self, liquidation, accounts, local):
        blockTime = chain.time()
        collateral = random.choice([c for c in range(1, 5) if c != local])
        assets = liquidation.get_fcash_portfolio(collateral, 100e8, 2, blockTime)
        liquidation.mock.setPortfolio(accounts[0], ([], assets, 0, 0))
        liquidation.mock.setBalance(accounts[0], local, -500_000e8, 0)

        maturities = [assets[0][1]] * 2
        with brownie.reverts():
            liquidation.mock.calculatefCashCrossCurrencyLiquidation.call(
                accounts[0],
                local,
                collateral,
                maturities,
                [0] * len(maturities),
                chain.time() + 1,
                {"from": accounts[1]},
            )
