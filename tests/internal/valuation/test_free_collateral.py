import logging
import random
from collections import OrderedDict

import pytest
from brownie.convert import to_bytes
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import (
    HAS_ASSET_DEBT,
    HAS_CASH_DEBT,
    SECONDS_IN_DAY,
    SECONDS_IN_QUARTER,
    START_TIME,
    START_TIME_TREF,
)
from tests.helpers import get_fcash_token, get_portfolio_array
from tests.internal.liquidation.liquidation_helpers import ValuationMock

LOGGER = logging.getLogger(__name__)
chain = Chain()

"""
Account Context:
    nextSettleTime:
        in past, revert
        else, proceed
"""


@pytest.mark.valuation
class TestFreeCollateral:
    @pytest.fixture(scope="module", autouse=True)
    def freeCollateral(self, MockFreeCollateral, accounts):
        return ValuationMock(accounts[0], MockFreeCollateral)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def get_fc_and_net_local(self, freeCollateral, accounts):
        chain.mine(1, timedelta=10)
        txn = freeCollateral.mock.testFreeCollateral(accounts[0])
        fc = txn.events["FreeCollateralResult"][0]["fc"]
        netLocal = txn.events["FreeCollateralResult"][0]["netLocal"]

        return (fc, netLocal, txn)

    def set_random_balances(self, freeCollateral, accounts, bitmapCurrency=0):
        for currency in range(1, 3):
            cashBalance = random.randint(-100_000e8, 100_000e8)
            nTokens = random.randint(0, 100_000e8)
            freeCollateral.mock.setBalance(accounts[0], currency, cashBalance, nTokens)

    # Test Single Free Collateral Components
    @given(
        currency=strategy("uint", min_value=1, max_value=3),
        balance=strategy("uint", min_value=0.01e8, max_value=10_000e8),
    )
    def test_single_positive_cash_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.mock.setBalance(accounts[0], currency, balance, 0)
        txn = freeCollateral.mock.testFreeCollateral(accounts[0])
        fc = txn.events["FreeCollateralResult"][0]["fc"]
        netLocal = txn.events["FreeCollateralResult"][0]["netLocal"]

        assert netLocal[0] == balance

        underlying = freeCollateral.calculate_to_underlying(currency, balance, txn.timestamp)
        ethFC = freeCollateral.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=2) == ethFC

    @given(
        currency=strategy("uint", min_value=1, max_value=3),
        balance=strategy("int", min_value=-100_000e8, max_value=0),
        offset=strategy("uint", min_value=SECONDS_IN_DAY, max_value=SECONDS_IN_QUARTER),
    )
    def test_single_negative_cash_balance(
        self, freeCollateral, accounts, currency, balance, offset
    ):
        freeCollateral.mock.setBalance(accounts[0], currency, balance, 0)
        (fc, netLocal, txn) = self.get_fc_and_net_local(freeCollateral, accounts)
        (cashBalance, _, _, _) = freeCollateral.mock.getBalance(
            accounts[0], currency, txn.timestamp
        )
        assert netLocal[0] == cashBalance

        underlying = freeCollateral.calculate_to_underlying(currency, cashBalance, txn.timestamp)
        ethFC = freeCollateral.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

        # Apply some offset and check that the FC becomes more negative as time progresses
        chain.mine(1, timedelta=offset)
        (fc2, netLocal2, _) = self.get_fc_and_net_local(freeCollateral, accounts)

        # Some rounding errors that cause it not to accrue debt
        if balance < -1e8:
            assert netLocal2[0] < netLocal[0]
            assert fc2 <= fc
        else:
            assert netLocal2[0] <= netLocal[0]
            assert fc2 <= fc

    # nToken Balance
    @given(
        currency=strategy("uint", min_value=1, max_value=3),
        balance=strategy("uint", min_value=0, max_value=100_000e8),
    )
    def test_single_ntoken_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.mock.setBalance(accounts[0], currency, 0, balance)
        (fc, netLocal, txn) = self.get_fc_and_net_local(freeCollateral, accounts)
        nTokenLocalAsset = freeCollateral.calculate_ntoken_to_asset(
            currency, balance, txn.timestamp
        )

        assert pytest.approx(netLocal[0], abs=1) == nTokenLocalAsset

        underlying = freeCollateral.calculate_to_underlying(
            currency, nTokenLocalAsset, txn.timestamp
        )
        ethFC = freeCollateral.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    # Portfolio Valuation
    @given(numAssets=strategy("uint", min_value=0, max_value=6))
    def test_portfolio_valuation(self, freeCollateral, accounts, numAssets):
        self.set_random_balances(freeCollateral, accounts)
        balanceAssetPV = OrderedDict({})

        cashGroups = [(1, 3), (2, 3), (3, 3)]
        assets = get_portfolio_array(numAssets, cashGroups, sorted=True)
        freeCollateral.mock.setPortfolio(accounts[0], ([], assets, 0, 0))

        (fc, netLocal, txn) = self.get_fc_and_net_local(freeCollateral, accounts)
        for i in range(1, 4):
            (cashBalance, nTokenBalance, _, _) = freeCollateral.mock.getBalance(
                accounts[0], i, txn.timestamp
            )
            nTokenPrime = freeCollateral.calculate_ntoken_to_asset(i, nTokenBalance, txn.timestamp)
            balanceAssetPV[i] = cashBalance + nTokenPrime

        i = 0
        while i < len(assets):
            currency = assets[i][0]
            (assetCashValue, i) = freeCollateral.mock.getNetCashGroupValue(assets, txn.timestamp, i)

            # Check that net local is correct on each loop
            balanceAssetPV[currency] += assetCashValue

            if i < len(assets):
                # Assert that the currency id is split
                assert assets[i - 1][0] < assets[i][0]
            elif i == len(assets):
                # i == len(assets) then we break, reached end
                break
            else:
                # Should not reach this condition
                assert False

        # Get any other currencies that we haven't caught in the loop above
        ethFC = 0
        netLocalIndex = 0
        for currency in balanceAssetPV.keys():
            underlying = freeCollateral.calculate_to_underlying(
                currency, balanceAssetPV[currency], txn.timestamp
            )
            ethFC += freeCollateral.calculate_to_eth(currency, underlying)

            assert pytest.approx(netLocal[netLocalIndex], abs=1) == balanceAssetPV[currency]
            netLocalIndex += 1

        assert pytest.approx(fc, abs=500) == ethFC

    @given(
        numAssets=strategy("uint", min_value=0, max_value=10),
        currency=strategy("uint", min_value=1, max_value=3),
    )
    def test_bitmap_valuation(self, freeCollateral, accounts, numAssets, currency):
        freeCollateral.enableBitmapForAccount(accounts[0], currency, START_TIME_TREF)
        self.set_random_balances(freeCollateral, accounts, bitmapCurrency=currency)
        balanceAssetPV = OrderedDict({})

        assets = []
        for i in range(0, numAssets):
            bitNum = random.randint(1, 130)
            maturity = freeCollateral.mock.getMaturityFromBitNum(START_TIME_TREF, bitNum)
            notional = random.randint(-500_000e8, 500_000e8)
            assets.append(
                get_fcash_token(0, maturity=maturity, notional=notional, currencyId=currency)
            )

        freeCollateral.mock.setBitmapAssets(accounts[0], assets)
        portfolio = freeCollateral.mock.getBitmapAssets(accounts[0])

        (fc, netLocal, txn) = self.get_fc_and_net_local(freeCollateral, accounts)
        presentValue = 0
        for asset in portfolio:
            presentValue += freeCollateral.mock.getRiskAdjustedPresentfCashValue(
                asset, txn.timestamp
            )

        for i in range(1, 4):
            (cashBalance, nTokenBalance, _, _) = freeCollateral.mock.getBalance(
                accounts[0], i, txn.timestamp
            )
            nTokenPrime = freeCollateral.calculate_ntoken_to_asset(i, nTokenBalance, txn.timestamp)
            balanceAssetPV[i] = cashBalance + nTokenPrime

        balanceAssetPV[currency] += freeCollateral.calculate_from_underlying(
            currency, presentValue, txn.timestamp
        )
        bitmapBalanceUnderlying = freeCollateral.calculate_to_underlying(
            currency, balanceAssetPV[currency], txn.timestamp
        )

        # The first netLocal value will be the bitmap portfolio's currency
        assert pytest.approx(netLocal[0], abs=1) == balanceAssetPV[currency]
        balanceAssetPV.pop(currency)

        netLocalIndex = 1
        ethFC = freeCollateral.calculate_to_eth(currency, bitmapBalanceUnderlying)
        # Check the remaining keys
        for c in balanceAssetPV.keys():
            underlying = freeCollateral.calculate_to_underlying(c, balanceAssetPV[c], txn.timestamp)
            ethFC += freeCollateral.calculate_to_eth(c, underlying)

            assert pytest.approx(netLocal[netLocalIndex], abs=1) == balanceAssetPV[c]
            netLocalIndex += 1

        assert pytest.approx(fc, abs=150) == ethFC

    # Test Update Context, these tests also check that FC does NOT update the
    # method if not required.
    # Bitmap Has Asset Debt
    # Bitmap Has Cash Debt
    # Array Has Cash Debt
    def test_bitmap_has_asset_debt(self, freeCollateral, accounts):
        freeCollateral.enableBitmapForAccount(accounts[0], 1, START_TIME_TREF)

        freeCollateral = freeCollateral.mock
        freeCollateral.setBitmapAssets(
            accounts[0],
            [
                get_fcash_token(
                    0, currencyId=1, maturity=START_TIME_TREF + SECONDS_IN_DAY * 5, notional=-100e8
                )
            ],
        )
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        # Bitmap continues to have debt
        freeCollateral.testFreeCollateral(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        # Bitmap debt is now net off, but context does not update
        freeCollateral.setBitmapAssets(
            accounts[0],
            [
                get_fcash_token(
                    0, currencyId=1, maturity=START_TIME_TREF + SECONDS_IN_DAY * 5, notional=500e8
                )
            ],
        )
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        txn = freeCollateral.testFreeCollateral(accounts[0])
        assert txn.events["AccountContextUpdate"]
        context = freeCollateral.getAccountContext(accounts[0])
        # No longer has any debt
        assert context[1] == "0x00"

    def test_array_remove_cash_debt(self, freeCollateral, accounts):
        freeCollateral = freeCollateral.mock
        freeCollateral.setBalance(accounts[0], 1, -200e8, 0)
        freeCollateral.setBalance(accounts[0], 2, 400e8, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        # Account still has cash debt, must not change setting
        freeCollateral.testFreeCollateral(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        freeCollateral.setBalance(accounts[0], 1, 0, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        # Cash debt setting is still temporarily on
        assert context[1] == HAS_CASH_DEBT

        txn = freeCollateral.testFreeCollateral(accounts[0])
        assert txn.events["AccountContextUpdate"]
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == "0x00"  # no debt

    def test_remove_cash_debt_bitmap_currency(self, freeCollateral, accounts):
        freeCollateral.enableBitmapForAccount(accounts[0], 1, START_TIME)

        freeCollateral = freeCollateral.mock
        freeCollateral.setBalance(accounts[0], 1, -200e8, 0)
        freeCollateral.setBalance(accounts[0], 2, 400e8, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        # Account still has cash debt, must not change setting
        freeCollateral.testFreeCollateral(accounts[0])
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        freeCollateral.setBalance(accounts[0], 1, 0, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        # Cash debt setting is still temporarily on
        assert context[1] == HAS_CASH_DEBT

        txn = freeCollateral.testFreeCollateral(accounts[0])
        assert txn.events["AccountContextUpdate"]
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == "0x00"  # no debt

    def validate_liquidation_factors(self, account, freeCollateral, local, collateral, isBitmap):
        txn = freeCollateral.mock.getLiquidationFactors(account, local, collateral)
        factors = txn.events["Liquidation"][0]["factors"]

        if isBitmap:
            portfolio = freeCollateral.mock.getBitmapAssets(account)
        else:
            portfolio = freeCollateral.mock.getPortfolio(account)

        balances = []
        for i in range(1, 5):
            (cashBalance, nTokenBalance, _, _) = freeCollateral.mock.getBalance(
                account, i, txn.timestamp
            )
            balances.append((i, cashBalance, nTokenBalance))

        localBalance = list(filter(lambda x: x[0] == local, balances))[0]
        localAssets = list(filter(lambda x: x[0] == local, portfolio))
        portfolioValue = 0
        for asset in localAssets:
            portfolioValue += freeCollateral.mock.getRiskAdjustedPresentfCashValue(
                asset, txn.timestamp
            )

        localAssetAvailable = (
            localBalance[1]
            + freeCollateral.calculate_ntoken_to_asset(local, localBalance[2], txn.timestamp)
            + freeCollateral.calculate_from_underlying(local, portfolioValue, txn.timestamp)
        )
        nTokenHaircutAssetValue = freeCollateral.calculate_ntoken_to_asset(
            local, localBalance[2], txn.timestamp
        )

        collateralAssetAvailable = 0
        if collateral > 0:
            collateralBalance = list(filter(lambda x: x[0] == collateral, balances))[0]
            collateralAssets = list(filter(lambda x: x[0] == collateral, portfolio))
            nTokenHaircutAssetValue = freeCollateral.calculate_ntoken_to_asset(
                collateral, collateralBalance[2], txn.timestamp
            )

            portfolioValue = 0
            for asset in collateralAssets:
                portfolioValue += freeCollateral.mock.getRiskAdjustedPresentfCashValue(
                    asset, txn.timestamp
                )

            collateralAssetAvailable = (
                collateralBalance[1]
                + freeCollateral.calculate_ntoken_to_asset(
                    collateral, collateralBalance[2], txn.timestamp
                )
                + freeCollateral.calculate_from_underlying(
                    collateral, portfolioValue, txn.timestamp
                )
            )

        # Account address
        assert factors[0] == account.address
        # Net ETH Value, no need to test this, it is validated above
        assert factors[1] < 0
        # Local Asset Available
        assert pytest.approx(factors[2], abs=1) == localAssetAvailable
        # Collateral Asset Available
        assert pytest.approx(factors[3], abs=1) == collateralAssetAvailable
        # nTokenHaircut Asset Available
        assert pytest.approx(factors[4], abs=1) == nTokenHaircutAssetValue

        # nTokenParameters (loaded if nTokens are in portfolio)
        if collateral > 0 and collateralBalance[2] > 0:
            assert int(factors[5].hex()[6:8], 16) == freeCollateral.nTokenParameters[collateral][0]
            assert int(factors[5].hex()[0:2], 16) == freeCollateral.nTokenParameters[collateral][1]
        elif collateral == 0 and localBalance[2] > 0:
            assert int(factors[5].hex()[6:8], 16) == freeCollateral.nTokenParameters[local][0]
            assert int(factors[5].hex()[0:2], 16) == freeCollateral.nTokenParameters[local][1]
        else:
            assert factors[5] == "0x000000000000"

        # Local ETH Rate
        localETHRate = freeCollateral.mock.getETHRate(local)
        assert factors[6][0] == 1e18  # Rate Decimals
        assert factors[6][1] == freeCollateral.ethRates[local]  # Rate
        assert factors[6][2:] == localETHRate[3:]
        # Collateral ETH Rate
        if collateral > 0:
            collateralETHRate = freeCollateral.mock.getETHRate(collateral)
            assert factors[7][0] == 1e18  # Rate Decimals
            assert factors[7][1] == freeCollateral.ethRates[collateral]  # Rate
            assert factors[7][2:] == collateralETHRate[3:]
        else:
            assert factors[7] == (0, 0, 0, 0, 0)

        # Local Prime Rate
        assert factors[8] == freeCollateral.mock.buildPrimeRateView(local, txn.timestamp)[0]

        # Cash Group Parameters
        # Cash group will be loaded if there are assets or nTokens
        if collateral == 0 and (len(localAssets) > 0 or localBalance[2] > 0):
            assert factors["collateralCashGroup"]["currencyId"] == local
        elif collateral > 0 and (len(collateralAssets) > 0 or collateralBalance[2] > 0):
            assert factors["collateralCashGroup"]["currencyId"] == collateral
        else:
            assert factors["collateralCashGroup"]["currencyId"] == 0

        if collateral != 0:
            # Cash group asset rate reference set to collateral
            assert (
                factors["collateralCashGroup"]["primeRate"]
                == freeCollateral.mock.buildPrimeRateView(collateral, txn.timestamp)[0]
            )
        elif len(localAssets) > 0 or localBalance[2] > 0:
            # Cash group asset rate reference set to local if it has assets
            assert (
                factors["collateralCashGroup"]["primeRate"]
                == freeCollateral.mock.buildPrimeRateView(local, txn.timestamp)[0]
            )
        else:
            # This is the case during local liquidation if there are only cash assets in
            # the local currency, there is no way to liquidate in this way
            assert factors["collateralCashGroup"]["primeRate"] == (0, 0, 0)

        # isCalculation == false
        assert not factors[10]

    # Test Liquidation Factors
    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_bitmap_liquidation_factors(self, freeCollateral, accounts, local):
        # Setup undercollateralized account
        freeCollateral.enableBitmapForAccount(accounts[0], local, START_TIME_TREF)
        freeCollateral.mock.setBalance(accounts[0], 1, -100e8, 200e8)
        freeCollateral.mock.setBalance(accounts[0], 2, 200e8, 100e8)
        freeCollateral.mock.setBalance(accounts[0], 3, -300e8, 0)
        freeCollateral.mock.setBalance(accounts[0], 4, 400e8, 0)

        # Leave this here to establish a large negative FC
        freeCollateral.mock.setBitmapAssets(
            accounts[0],
            [
                get_fcash_token(
                    0,
                    currencyId=local,
                    maturity=START_TIME_TREF + SECONDS_IN_DAY * 30,
                    notional=-100_000e8,
                )
            ],
        )

        for c in range(0, 5):
            if c == local:
                continue
            self.validate_liquidation_factors(accounts[0], freeCollateral, local, c, True)

    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_array_liquidation_factors(self, freeCollateral, accounts, local):
        # This one should have a large negative balance to establish negative fc
        freeCollateral.mock.setBalance(accounts[0], 1, -100e8, 200e8)
        freeCollateral.mock.setBalance(accounts[0], 2, 200e8, 100e8)
        freeCollateral.mock.setBalance(accounts[0], 3, -300e8, 0)
        freeCollateral.mock.setBalance(accounts[0], 4, 400e8, 0)

        freeCollateral.mock.setPortfolio(
            accounts[0],
            (
                [],
                [
                    get_fcash_token(1, currencyId=1, notional=-100_000e8),
                    get_fcash_token(1, currencyId=3, notional=-100_000e8),
                ],
                0,
                0,
            ),
        )

        for c in range(0, 5):
            if c == local:
                continue
            self.validate_liquidation_factors(accounts[0], freeCollateral, local, c, False)
