import logging

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import get_fcash_token
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    calculate_local_debt_cash_balance,
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
        MockLocalfCashLiquidation,
        SettleAssetsExternal,
        FreeCollateralAtTime,
        FreeCollateralExternal,
        TradingAction,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        FreeCollateralAtTime.deploy({"from": accounts[0]})
        TradingAction.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockLocalfCashLiquidation)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def calculate_local_benefit(self, liquidation, local, assets, ratio, blockTime):
        totalBenefit = 0
        totalHaircut = 0
        for a in assets:
            haircut = liquidation.discount_to_pv(local, a[3], a[1], blockTime, "haircut")
            liquidator = liquidation.discount_to_pv(local, a[3], a[1], blockTime, "liquidator")
            totalHaircut += haircut
            totalBenefit += abs(liquidator - haircut)

        cashUnderlying = -Wei(totalHaircut + (totalBenefit * ratio * 1e8) / 1e10)
        cashAsset = liquidation.calculate_from_underlying(local, cashUnderlying, blockTime)

        return (cashAsset, totalBenefit, totalHaircut)

    def validate_transfers(
        self, liquidation, accounts, local, assets, localCash, bitmap, blockTime
    ):
        # Set the fCash asset
        if bitmap:
            liquidation.mock.setBitmapAssets(accounts[0], assets)
        else:
            state = liquidation.mock.buildPortfolioState(accounts[0])
            for a in assets:
                state = liquidation.mock.addAsset(state, a[0], a[1], 1, a[3])
            liquidation.mock.setPortfolio(accounts[0], state)

        (fcBefore, netLocalBefore) = liquidation.mock.getFreeCollateral(
            accounts[0], chain.time() + 1
        )
        maturities = sorted([a[1] for a in assets], reverse=True)
        blockTime = chain.time()
        (
            notionalTransfers,
            localAssetCashFromLiquidator,
        ) = liquidation.mock.calculatefCashLocalLiquidation.call(
            accounts[0], local, maturities, [0] * len(maturities), blockTime, {"from": accounts[1]}
        )

        txn = liquidation.mock.calculatefCashLocalLiquidation(
            accounts[0], local, maturities, [0] * len(maturities), blockTime, {"from": accounts[1]}
        )

        transfers = []
        liquidatorPrice = 0
        fCashBenefit = 0
        for (m, t) in zip(maturities, notionalTransfers):
            # Test the expected fcash transfer
            # assert pytest.approx(e, rel=1e-6) == t

            matchingfCash = list(filter(lambda x: x[1] == m, assets))[0]
            # Transfer cannot exceed fCash balance.
            assert abs(matchingfCash[3]) >= abs(t)

            transfers.append(get_fcash_token(1, currencyId=local, maturity=m, notional=-t))
            liquidator = liquidation.discount_to_pv(local, t, m, txn.timestamp, "liquidator")
            haircut = liquidation.discount_to_pv(local, t, m, txn.timestamp, "haircut")

            liquidatorPrice += liquidator
            fCashBenefit += liquidator - haircut

        # Check price is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, rel=1e-6
        ) == liquidation.calculate_from_underlying(local, liquidatorPrice, txn.timestamp)

        # Simulate transfer
        if bitmap:
            liquidation.mock.setBitmapAssets(accounts[0], transfers)
            portfolioAfter = liquidation.mock.getBitmapAssets(accounts[0])
        else:
            state = liquidation.mock.buildPortfolioState(accounts[0])
            for a in transfers:
                state = liquidation.mock.addAsset(state, a[0], a[1], 1, a[3])
            liquidation.mock.setPortfolio(accounts[0], state)
            portfolioAfter = liquidation.mock.getPortfolio(accounts[0])

        liquidation.mock.setBalance(accounts[0], local, localCash + localAssetCashFromLiquidator, 0)
        blockTime = chain.time() + 1
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0], blockTime)

        # There cannot be a situation with a negative benefit
        assert fCashBenefit > 0
        actualBenefitAsset = liquidation.calculate_from_underlying(local, fCashBenefit, blockTime)
        return (
            fcBefore,
            netLocalBefore,
            fcAfter,
            netLocalAfter,
            portfolioAfter,
            fCashBenefit,
            txn,
            actualBenefitAsset,
        )

    @given(
        fCashPV=strategy(
            "int",
            min_value=-100_000e8,
            max_value=100_000e8,
            exclude=lambda x: not (-100e8 < x and x < 100e8),
        ),
        local=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
        bitmap=strategy("bool"),
        numAssets=strategy("uint", min_value=1, max_value=5),
    )
    def test_local_fcash_negative_available(
        self, liquidation, accounts, fCashPV, local, ratio, bitmap, numAssets
    ):
        blockTime = chain.time()
        if bitmap:
            liquidation.enableBitmapForAccount(accounts[0], local, blockTime)

        assets = liquidation.get_fcash_portfolio(local, fCashPV, numAssets, blockTime)
        (cashAsset, totalBenefit, _) = self.calculate_local_benefit(
            liquidation, local, assets, ratio, blockTime
        )
        liquidation.mock.setBalance(accounts[0], local, cashAsset, 0)

        (
            fcBefore,
            netLocalBefore,
            fcAfter,
            netLocalAfter,
            portfolioAfter,
            fCashBenefit,
            txn,
            actualBenefitAsset,
        ) = self.validate_transfers(
            liquidation, accounts, local, assets, cashAsset, bitmap, blockTime
        )

        # This will guarantee that netLocal increases
        assert (
            pytest.approx(netLocalAfter[0] - netLocalBefore[0], rel=1e-3, abs=500)
            == actualBenefitAsset
        )

        if ratio >= 100:
            # In this scenario we liquidate all local asset and are still undercollateralized. If
            # fCash is positive then the portfolio will be empty, if fCash is negative then the cash
            # balance will be near zero
            (cashBalance, _, _, _) = liquidation.mock.getBalance(
                accounts[0], local, chain.time() + 1
            )
            assert len(portfolioAfter) == 0 or cashBalance < 5_000
            assert fcAfter <= 0
        else:
            # In this case we should have sufficient fCash to liquidate, the last fCash asset that
            # remains should have been liquidated by at least 40% (i.e. < 60% remains), whether or
            # not the randomized collateral ratio given into this method is less than or equal to
            # 40% does not matter since each fCash asset is treated discretely. It is possible that
            # there is a given ratio of 40% but we can still end up liquidating well into positive
            # free collateral
            remainingAssetBefore = list(filter(lambda a: a[1] == portfolioAfter[-1][1], assets))
            liquidatedNotional = portfolioAfter[-1][3] / remainingAssetBefore[0][3]
            assert liquidatedNotional <= 0.600001

            assert fcAfter > fcBefore and fcAfter >= -0.01e8

    @given(
        fCashPV=strategy(
            "int",
            min_value=-100_000e8,
            max_value=100_000e8,
            exclude=lambda x: not (-100e8 < x and x < 100e8),
        ),
        local=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=25, max_value=150),
        bitmap=strategy("bool"),
        numAssets=strategy("uint", min_value=1, max_value=5),
    )
    def test_local_fcash_positive_available(
        self, liquidation, accounts, fCashPV, local, ratio, bitmap, numAssets
    ):
        blockTime = chain.time()
        if bitmap:
            liquidation.enableBitmapForAccount(accounts[0], local, blockTime)

        assets = liquidation.get_fcash_portfolio(local, fCashPV, numAssets, blockTime)
        (_, totalBenefit, totalHaircut) = self.calculate_local_benefit(
            liquidation, local, assets, ratio, blockTime
        )
        totalBenefitAsset = liquidation.calculate_from_underlying(local, totalBenefit, blockTime)
        totalHaircutAsset = liquidation.calculate_from_underlying(local, totalHaircut, blockTime)

        cashAsset = 0
        if fCashPV < 0:
            # If fCashPV is negative, we need to add enough cash to offset the debt. Increase it
            # slightly so that we ensure we are in positive collateral territory, hovering around
            # zero leads to flakiness in the test.
            cashAsset = Wei(
                liquidation.calculate_from_underlying(local, -fCashPV, blockTime) * 1.10
            )
            (debtCurrency, debtCashBalance) = calculate_local_debt_cash_balance(
                liquidation,
                local,
                ratio,
                totalBenefitAsset,
                totalHaircutAsset + cashAsset,
                blockTime,
            )
        else:
            (debtCurrency, debtCashBalance) = calculate_local_debt_cash_balance(
                liquidation, local, ratio, totalBenefitAsset, totalHaircutAsset, blockTime
            )

        liquidation.mock.setBalance(accounts[0], debtCurrency, debtCashBalance, 0)
        liquidation.mock.setBalance(accounts[0], local, cashAsset, 0)
        (
            fcBefore,
            netLocalBefore,
            fcAfter,
            netLocalAfter,
            portfolioAfter,
            fCashBenefit,
            txn,
            actualBenefitAsset,
        ) = self.validate_transfers(
            liquidation, accounts, local, assets, cashAsset, bitmap, blockTime
        )

        index = 0 if bitmap or local < debtCurrency else 1
        # This will guarantee that netLocal increases
        assert (
            pytest.approx(netLocalAfter[index] - netLocalBefore[index], rel=1e-4, abs=5_000)
            == actualBenefitAsset
        )

        if ratio >= 100:
            # In this scenario we liquidate all local asset and are still undercollateralized. If
            # fCash is positive then the portfolio will be empty, if fCash is negative then the cash
            # balance will be near zero
            balances = liquidation.mock.getBalance(accounts[0], local, chain.time() + 1)
            assert len(portfolioAfter) == 0 or balances[1] < 100
            assert fcAfter <= 10
        else:
            # In this case we should have sufficient fCash to liquidate, the last fCash asset that
            # remains should have been liquidated by at least 40% (i.e. < 60% remains), whether or
            # not the randomized collateral ratio given into this method is less than or equal to
            # 40% does not matter since each fCash asset is treated discretely. It is possible that
            # there is a given ratio of 40% but we can still end up liquidating well into positive
            # free collateral
            remainingAssetBefore = list(filter(lambda a: a[1] == portfolioAfter[-1][1], assets))
            liquidatedNotional = portfolioAfter[-1][3] / remainingAssetBefore[0][3]
            assert liquidatedNotional <= 0.600001
            assert fcAfter > fcBefore and fcAfter >= -0.01e8

    @given(
        fCashPV=strategy(
            "int",
            min_value=-100_000e8,
            max_value=100_000e8,
            exclude=lambda x: not (-100e8 < x and x < 100e8),
        ),
        bitmap=strategy("bool"),
        numAssets=strategy("uint", min_value=1, max_value=5),
    )
    def test_local_fcash_user_limit(self, liquidation, accounts, fCashPV, bitmap, numAssets):
        local = 1
        fCashPV = 1000e8
        ratio = 100

        blockTime = chain.time()
        if bitmap:
            liquidation.enableBitmapForAccount(accounts[0], local, blockTime)

        assets = liquidation.get_fcash_portfolio(local, fCashPV, numAssets, blockTime)
        (cashAsset, totalBenefit, _) = self.calculate_local_benefit(
            liquidation, local, assets, ratio, blockTime
        )

        # Set fCash assets
        if bitmap:
            liquidation.mock.setBitmapAssets(accounts[0], assets)
        else:
            liquidation.mock.setPortfolio(accounts[0], ([], assets, 0, 0))

        liquidation.mock.setBalance(accounts[0], local, cashAsset, 0)
        maturities = sorted([a[1] for a in assets], reverse=True)
        maxNotionalToTransfer = [1e8] * len(maturities)
        chain.mine(1)
        (
            notionalTransfers,
            localAssetCashFromLiquidator,
        ) = liquidation.mock.calculatefCashLocalLiquidation.call(
            accounts[0],
            local,
            maturities,
            maxNotionalToTransfer,
            chain.time() + 1,
            {"from": accounts[1]},
        )

        for (i, n) in enumerate(notionalTransfers):
            assert abs(n) <= maxNotionalToTransfer[i]

    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_local_fcash_no_duplicate_maturities(self, liquidation, accounts, local):
        blockTime = chain.time()
        assets = liquidation.get_fcash_portfolio(local, 100e8, 1, blockTime)
        liquidation.mock.setPortfolio(accounts[0], ([], assets, 0, 0))
        liquidation.mock.setBalance(accounts[0], local, -200e8, 0)

        maturities = sorted([a[1] for a in assets], reverse=True) * 2
        with brownie.reverts():
            liquidation.mock.calculatefCashLocalLiquidation(
                accounts[0],
                local,
                maturities,
                [0] * len(maturities),
                blockTime,
                {"from": accounts[1]},
            )
