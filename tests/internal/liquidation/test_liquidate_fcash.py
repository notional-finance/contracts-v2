import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import get_fcash_token
from tests.internal.liquidation.liquidation_helpers import ValuationMock

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
        MockLocalfCashLiquidation,
        SettleAssetsExternal,
        FreeCollateralAtTime,
        FreeCollateralExternal,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        FreeCollateralAtTime.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockLocalfCashLiquidation)

    @pytest.mark.only
    @given(
        fCash=strategy("uint", min_value=100e8, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
        bitmap=strategy("bool"),
    )
    def test_local_fcash_positive_available_positive_fcash(
        self, liquidation, accounts, fCash, currency, ratio, bitmap
    ):
        # todo: allow this to be idiosyncratic
        marketIndex = 3
        fCashAsset = get_fcash_token(marketIndex, currencyId=currency, notional=fCash)
        maturity = fCashAsset[1]

        blockTime = chain.time()
        oracleRate = liquidation.mock.calculateOracleRate(currency, fCashAsset[1], blockTime)
        haircut = liquidation.discount_to_pv(
            currency, fCash, oracleRate, maturity, blockTime, "haircut"
        )
        liquidator = liquidation.discount_to_pv(
            currency, fCash, oracleRate, maturity, blockTime, "liquidator"
        )
        benefit = liquidator - haircut

        # Set the fCash asset
        if bitmap:
            liquidation.mock.enableBitmapForAccount(accounts[0], currency, chain.time())
            liquidation.mock.setifCashAsset(accounts[0], currency, maturity, fCash)
        else:
            liquidation.mock.setPortfolio(accounts[0], [fCashAsset])

        cashUnderlying = -Wei(haircut + (benefit * ratio * 1e8) / 1e10)
        cashAsset = liquidation.calculate_from_underlying(currency, cashUnderlying)
        liquidation.mock.setBalance(accounts[0], currency, cashAsset, 0)

        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)

        (
            notionalTransfers,
            localAssetCashFromLiquidator,
        ) = liquidation.mock.calculatefCashLocalLiquidation.call(
            accounts[0], currency, [maturity], [0], blockTime, {"from": accounts[1]}
        )

        # Check price is correct
        liquidationPrice = liquidation.discount_to_pv(
            currency, notionalTransfers[0], oracleRate, maturity, blockTime, "liquidator"
        )
        assert pytest.approx(
            localAssetCashFromLiquidator, rel=1e-8
        ) == liquidation.calculate_from_underlying(currency, liquidationPrice)

        # Simulate transfer
        # Cannot exceed balance
        assert notionalTransfers[0] <= fCash
        if bitmap:
            liquidation.mock.setifCashAsset(accounts[0], currency, maturity, -notionalTransfers[0])
        else:
            transfer = get_fcash_token(
                marketIndex, currencyId=currency, notional=-notionalTransfers[0]
            )
            liquidation.mock.setPortfolio(accounts[0], [transfer])

        liquidation.mock.setBalance(
            accounts[0], currency, cashAsset + localAssetCashFromLiquidator, 0
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)

        benefitAsset = liquidation.calculate_from_underlying(currency, benefit)
        if ratio <= 40:
            # In the case that the ratio is less than 40%, we liquidate up to 40%
            assert (
                pytest.approx(Wei(netLocal[0] + benefitAsset * 0.40), rel=1e-5) == netLocalAfter[0]
            )
            assert fcAfter > 0
        elif ratio > 100:
            # In this scenario we liquidate all the fCash and are still undercollateralized
            assert pytest.approx(notionalTransfers[0], rel=1e-5) == fCash
            assert pytest.approx(Wei(netLocal[0] + benefitAsset), rel=1e-5) == netLocalAfter[0]
            assert fcAfter < 0
        else:
            # In each of these scenarios sufficient fCash exists to liquidate to zero fc,
            # some dust will exist when rounding this back to zero, we may undershoot due to
            # truncation in solidity math
            assert pytest.approx(netLocalAfter[0], abs=1e5) == 0
            assert pytest.approx(fcAfter, abs=1e5) == 0

    def test_local_fcash_positive_available_negative_fcash(self, liquidation, accounts):
        pass

    def test_local_fcash_positive_available_both(self, liquidation, accounts):
        pass

    def test_local_fcash_negative_available_positive_fcash(self, liquidation, accounts):
        pass

    def test_local_fcash_negative_available_negative_fcash(self, liquidation, accounts):
        pass

    def test_local_fcash_negative_available_both(self, liquidation, accounts):
        pass

    def test_local_fcash_positive_available_user_limit(self, liquidation, accounts):
        pass

    def test_local_fcash_negative_available_user_limit(self, liquidation, accounts):
        pass

    def test_local_fcash_no_duplicate_maturities(self, liquidation, accounts):
        pass
