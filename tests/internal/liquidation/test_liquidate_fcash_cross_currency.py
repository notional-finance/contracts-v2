import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import get_fcash_token
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    get_expected,
    move_collateral_exchange_rate,
    setup_collateral_liquidation,
)

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

    @pytest.mark.only
    @given(
        localDebt=strategy("int", min_value=-1_000_000e8, max_value=-1e8),
        local=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
        numAssets=strategy("uint", min_value=1, max_value=5),
    )
    def test_cross_currency_fcash(self, liquidation, accounts, localDebt, local, ratio, numAssets):
        blockTime = chain.time()

        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)

        # Gets the collateral fCash asset to set the fc to ~ 0
        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )
        assets = liquidation.get_fcash_portfolio(
            collateral, collateralUnderlying, numAssets, blockTime
        )

        # Set the fCash asset (note: bitmaps cannot have cross currency fCash liquidations)
        liquidation.mock.setPortfolio(accounts[0], assets)

        # FC should be ~0 at this point
        (fc, _) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)
        assert pytest.approx(fc, abs=1e6) == 0

        # Moves the exchange rate based on the ratio
        (newExchangeRate, discountedExchangeRate) = move_collateral_exchange_rate(
            liquidation, local, collateral, ratio
        )

        # FC is be negative at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)

        # expectedNetETHBenefit only includes collateral benefit
        (expectedCollateralTrade, expectedNetETHBenefit, _, _) = get_expected(
            liquidation,
            local,
            collateral,
            newExchangeRate,
            discountedExchangeRate,
            collateralUnderlying,
            fc,
        )

        # Convert to expected fCash trade
        maturities = [a[1] for a in assets]
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

        transfers = []
        liquidatorPrice = 0
        fCashBenefit = 0
        for (m, t) in zip(maturities, notionalTransfers):
            # Test the expected fcash transfer
            # assert pytest.approx(e, rel=1e-6) == t

            matchingfCash = list(filter(lambda x: x[1] == m, assets))[0]
            # Transfer cannot exceed fCash balance.
            assert matchingfCash[3] >= t

            transfers.append(get_fcash_token(1, currencyId=collateral, maturity=m, notional=-t))
            liquidator = liquidation.discount_to_pv(collateral, t, m, blockTime, "liquidator")
            haircut = liquidation.discount_to_pv(collateral, t, m, blockTime, "haircut")

            liquidatorPrice += liquidator
            fCashBenefit += liquidator - haircut
        expectedNetETHBenefit -= liquidation.calculate_to_eth(collateral, fCashBenefit)

        # Check price is correct
        localCashFinal = liquidation.calculate_to_underlying(local, localAssetCashFromLiquidator)
        assert (
            pytest.approx((localCashFinal * discountedExchangeRate) / 1e18, rel=1e-6)
            == liquidatorPrice
        )

        # Simulate transfer
        liquidation.mock.setPortfolio(accounts[0], transfers)
        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)

        # Check that we did not cross available boundaries in the trade
        collateralAvailable = netLocalAfter[1 if collateral > local else 0]
        localAvailable = netLocalAfter[0 if collateral > local else 1]
        assert collateralAvailable >= 0
        assert localAvailable <= 0

        # Account for the fCash benefit in the trade
        # TODO: this is wrong...
        # assert pytest.approx(fc - expectedNetETHBenefit, rel=1e-2) == fcAfter

    def test_cross_currency_fcash_user_limit(self, liquidation, accounts):
        pass

    def test_cross_currency_fcash_no_duplicate_maturities(self, liquidation, accounts):
        pass
