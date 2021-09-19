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
    )
    def test_cross_currency_fcash(self, liquidation, accounts, localDebt, local, ratio):
        # todo: allow this to be idiosyncratic
        marketIndex = 3

        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)

        blockTime = chain.time()
        maturity = get_fcash_token(marketIndex)[1]

        # Gets the collateral fCash asset to set the fc to ~ 0
        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )
        fCash = liquidation.notional_from_pv(collateral, collateralUnderlying, maturity, blockTime)
        fCashAsset = get_fcash_token(marketIndex, currencyId=collateral, notional=fCash)

        # Set the fCash asset (note: bitmaps cannot have cross currency fCash liquidations)
        liquidation.mock.setPortfolio(accounts[0], [fCashAsset])

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
        (expectedCollateralTrade, expectedNetETHBenefit) = get_expected(
            liquidation,
            local,
            collateral,
            newExchangeRate,
            discountedExchangeRate,
            collateralUnderlying,
            fc,
        )

        # Convert to expected fCash trade
        expectedfCashTransfer = liquidation.notional_from_pv(
            collateral, expectedCollateralTrade, maturity, blockTime
        )

        (
            notionalTransfers,
            localAssetCashFromLiquidator,
        ) = liquidation.mock.calculatefCashCrossCurrencyLiquidation.call(
            accounts[0], local, collateral, [maturity], [0], blockTime, {"from": accounts[1]}
        )
        assert pytest.approx(expectedfCashTransfer, rel=1e-6) == notionalTransfers[0]

        # Check price is correct
        fCashPV = liquidation.discount_to_pv(
            collateral, notionalTransfers[0], maturity, blockTime, "liquidator"
        )
        localCashFinal = liquidation.calculate_to_underlying(local, localAssetCashFromLiquidator)
        assert pytest.approx((localCashFinal * discountedExchangeRate) / 1e18, rel=1e-6) == fCashPV

        # Simulate transfer
        # Cannot exceed balance
        assert notionalTransfers[0] <= fCash
        transfer = get_fcash_token(
            marketIndex, currencyId=collateral, notional=-notionalTransfers[0]
        )
        liquidation.mock.setPortfolio(accounts[0], [transfer])

        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )

        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)

        # Account for the fCash benefit in the trade
        # TODO: this is pretty inaccurate...
        haircut = liquidation.discount_to_pv(
            collateral, expectedfCashTransfer, maturity, blockTime, "haircut"
        )
        liquidator = liquidation.discount_to_pv(
            collateral, expectedfCashTransfer, maturity, blockTime, "liquidator"
        )
        benefit = liquidator - haircut
        expectedNetETHBenefit -= liquidation.calculate_to_eth(collateral, benefit)

        assert pytest.approx(fc - expectedNetETHBenefit, rel=1e-2) == fcAfter

    def test_cross_currency_fcash_user_limit(self, liquidation, accounts):
        pass

    def test_cross_currency_fcash_no_duplicate_maturities(self, liquidation, accounts):
        pass
