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

    def get_fc_and_net_local(self, freeCollateral, accounts, time=START_TIME):
        txn = freeCollateral.mock.testFreeCollateral(accounts[0], time)
        fc = txn.events["FreeCollateralResult"][0]["fc"]
        netLocal = txn.events["FreeCollateralResult"][0]["netLocal"]

        return (fc, netLocal, txn)

    def set_random_balances(self, freeCollateral, accounts, bitmapCurrency=0):
        balanceAssetPV = OrderedDict({})

        for currency in range(1, 5):
            if bitmapCurrency == currency:
                cashBalance = random.randint(0, 100_000e8)
            else:
                cashBalance = random.randint(-100_000e8, 100_000e8)

            nTokens = random.randint(0, 100_000e8)
            freeCollateral.mock.setBalance(accounts[0], currency, cashBalance, nTokens)
            nTokenAsset = freeCollateral.calculate_ntoken_to_asset(currency, nTokens)

            balanceAssetPV[currency] = nTokenAsset + cashBalance

        return balanceAssetPV

    # Test Single Free Collateral Components
    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        balance=strategy("uint", min_value=0, max_value=100_000_000e8),
    )
    def test_positive_cash_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.mock.setBalance(accounts[0], currency, balance, 0)
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        assert netLocal[0] == balance

        underlying = freeCollateral.calculate_to_underlying(currency, balance)
        ethFC = freeCollateral.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        balance=strategy("int", min_value=-100_000_000e8, max_value=0),
    )
    def test_negative_cash_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.mock.setBalance(accounts[0], currency, balance, 0)
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        assert netLocal[0] == balance

        underlying = freeCollateral.calculate_to_underlying(currency, balance)
        ethFC = freeCollateral.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    # nToken Balance
    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        balance=strategy("uint", min_value=0, max_value=10_000_000e8),
    )
    def test_ntoken_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.mock.setBalance(accounts[0], currency, 0, balance)
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        nTokenLocalAsset = freeCollateral.calculate_ntoken_to_asset(currency, balance)

        assert pytest.approx(netLocal[0], abs=1) == nTokenLocalAsset

        underlying = freeCollateral.calculate_to_underlying(currency, nTokenLocalAsset)
        ethFC = freeCollateral.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    # Portfolio Valuation
    @given(
        numAssets=strategy("uint", min_value=0, max_value=6),
        numCurrencies=strategy("uint", min_value=1, max_value=4),
    )
    def test_portfolio_valuation(self, freeCollateral, accounts, numAssets, numCurrencies):
        balanceAssetPV = self.set_random_balances(freeCollateral, accounts)

        cashGroups = []
        for i in range(1, numCurrencies + 1):
            cashGroups.append(freeCollateral.cashGroups[i])
        assets = get_portfolio_array(numAssets, cashGroups, sorted=True)
        freeCollateral.mock.setPortfolio(accounts[0], assets)

        i = 0
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        while i < len(assets):
            currency = assets[i][0]
            (assetCashValue, i) = freeCollateral.mock.getNetCashGroupValue(assets, START_TIME, i)

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
            underlying = freeCollateral.calculate_to_underlying(currency, balanceAssetPV[currency])
            ethFC += freeCollateral.calculate_to_eth(currency, underlying)

            assert netLocal[netLocalIndex] == balanceAssetPV[currency]
            netLocalIndex += 1

        assert pytest.approx(fc, abs=20) == ethFC

    @given(
        numAssets=strategy("uint", min_value=0, max_value=10),
        currency=strategy("uint", min_value=1, max_value=4),
    )
    def test_bitmap_valuation(self, freeCollateral, accounts, numAssets, currency):
        freeCollateral.mock.enableBitmapForAccount(accounts[0], currency, START_TIME_TREF)
        balanceAssetPV = self.set_random_balances(freeCollateral, accounts, bitmapCurrency=currency)

        for i in range(0, numAssets):
            bitNum = random.randint(1, 130)
            maturity = freeCollateral.mock.getMaturityFromBitNum(START_TIME_TREF, bitNum)
            notional = random.randint(-500_000e8, 500_000e8)
            freeCollateral.mock.setifCashAsset(accounts[0], currency, maturity, notional)

        (_, _, portfolio) = freeCollateral.mock.getAccount(accounts[0])

        presentValue = 0
        for asset in portfolio:
            presentValue += freeCollateral.mock.getRiskAdjustedPresentfCashValue(
                asset, START_TIME_TREF
            )

        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts, START_TIME_TREF)

        balanceAssetPV[currency] += freeCollateral.calculate_from_underlying(currency, presentValue)
        bitmapBalanceUnderlying = freeCollateral.calculate_to_underlying(
            currency, balanceAssetPV[currency]
        )
        # The first netLocal value will be the bitmap portfolio's currency
        assert pytest.approx(netLocal[0], abs=1) == balanceAssetPV.pop(currency)

        netLocalIndex = 1
        ethFC = freeCollateral.calculate_to_eth(currency, bitmapBalanceUnderlying)
        # Check the remaining keys
        for c in balanceAssetPV.keys():
            underlying = freeCollateral.calculate_to_underlying(c, balanceAssetPV[c])
            ethFC += freeCollateral.calculate_to_eth(c, underlying)

            assert netLocal[netLocalIndex] == balanceAssetPV[c]
            netLocalIndex += 1

        assert pytest.approx(fc, abs=20) == ethFC

    # Test Update Context, these tests also check that FC does NOT update the
    # method if not required.
    # Bitmap Has Asset Debt
    # Bitmap Has Cash Debt
    # Array Has Cash Debt
    def test_bitmap_has_asset_debt(self, freeCollateral, accounts):
        freeCollateral = freeCollateral.mock
        freeCollateral.enableBitmapForAccount(accounts[0], 1, START_TIME_TREF)
        freeCollateral.setifCashAsset(accounts[0], 1, START_TIME_TREF + SECONDS_IN_DAY * 5, -100e8)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        # Bitmap continues to have debt
        freeCollateral.testFreeCollateral(accounts[0], START_TIME_TREF)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        # Bitmap debt is now net off, but context does not update
        freeCollateral.setifCashAsset(accounts[0], 1, START_TIME_TREF + SECONDS_IN_DAY * 5, 500e8)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_ASSET_DEBT

        txn = freeCollateral.testFreeCollateral(accounts[0], START_TIME)
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
        freeCollateral.testFreeCollateral(accounts[0], START_TIME)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        freeCollateral.setBalance(accounts[0], 1, 0, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        # Cash debt setting is still temporarily on
        assert context[1] == HAS_CASH_DEBT

        txn = freeCollateral.testFreeCollateral(accounts[0], START_TIME)
        assert txn.events["AccountContextUpdate"]
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == "0x00"  # no debt

    def test_remove_cash_debt_bitmap_currency(self, freeCollateral, accounts):
        freeCollateral = freeCollateral.mock
        freeCollateral.enableBitmapForAccount(accounts[0], 1, START_TIME)
        freeCollateral.setBalance(accounts[0], 1, -200e8, 0)
        freeCollateral.setBalance(accounts[0], 2, 400e8, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        # Account still has cash debt, must not change setting
        freeCollateral.testFreeCollateral(accounts[0], START_TIME)
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == HAS_CASH_DEBT

        freeCollateral.setBalance(accounts[0], 1, 0, 0)
        context = freeCollateral.getAccountContext(accounts[0])
        # Cash debt setting is still temporarily on
        assert context[1] == HAS_CASH_DEBT

        txn = freeCollateral.testFreeCollateral(accounts[0], START_TIME)
        assert txn.events["AccountContextUpdate"]
        context = freeCollateral.getAccountContext(accounts[0])
        assert context[1] == "0x00"  # no debt

    def validate_liquidation_factors(self, account, freeCollateral, local, collateral):
        txn = freeCollateral.mock.getLiquidationFactors(account, START_TIME_TREF, local, collateral)
        factors = txn.events["Liquidation"][0]["factors"]
        (_, balances, portfolio) = freeCollateral.mock.getAccount(account)

        localBalance = list(filter(lambda x: x[0] == local, balances))[0]
        localAssets = list(filter(lambda x: x[0] == local, portfolio))
        portfolioValue = 0
        for asset in localAssets:
            portfolioValue += freeCollateral.mock.getRiskAdjustedPresentfCashValue(
                asset, START_TIME_TREF
            )

        localAssetAvailable = (
            localBalance[1]
            + freeCollateral.calculate_ntoken_to_asset(local, localBalance[2])
            + freeCollateral.calculate_from_underlying(local, portfolioValue)
        )
        nTokenHaircutAssetValue = freeCollateral.calculate_ntoken_to_asset(local, localBalance[2])

        collateralAssetAvailable = 0
        if collateral > 0:
            collateralBalance = list(filter(lambda x: x[0] == collateral, balances))[0]
            collateralAssets = list(filter(lambda x: x[0] == collateral, portfolio))
            nTokenHaircutAssetValue = freeCollateral.calculate_ntoken_to_asset(
                collateral, collateralBalance[2]
            )

            portfolioValue = 0
            for asset in collateralAssets:
                portfolioValue += freeCollateral.mock.getRiskAdjustedPresentfCashValue(
                    asset, START_TIME_TREF
                )

            collateralAssetAvailable = (
                collateralBalance[1]
                + freeCollateral.calculate_ntoken_to_asset(collateral, collateralBalance[2])
                + freeCollateral.calculate_from_underlying(collateral, portfolioValue)
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
        assert factors[6][0] == 1e18  # Rate Decimals
        assert factors[6][1] == freeCollateral.ethRates[local]  # Rate
        assert factors[6][2:] == freeCollateral.bufferHaircutDiscount[local]
        # Collateral ETH Rate
        if collateral > 0:
            assert factors[7][0] == 1e18  # Rate Decimals
            assert factors[7][1] == freeCollateral.ethRates[collateral]  # Rate
            assert factors[7][2:] == freeCollateral.bufferHaircutDiscount[collateral]
        else:
            assert factors[7] == (0, 0, 0, 0, 0)

        # Local Asset Rate
        assert factors[8] == (
            freeCollateral.cTokenAdapters[local].address,
            freeCollateral.cTokenRates[local],
            10 ** freeCollateral.underlyingDecimals[local],
        )
        # Cash Group Parameters
        # Cash group will be loaded if there are assets or nTokens
        if collateral == 0 and (len(localAssets) > 0 or localBalance[2] > 0):
            assert factors[9][0] == local
        elif collateral > 0 and (len(collateralAssets) > 0 or collateralBalance[2] > 0):
            assert factors[9][0] == collateral
        else:
            assert factors[9][0] == 0

        if collateral != 0:
            # Cash group asset rate reference set to collateral
            assert factors[9][2][0] == freeCollateral.cTokenAdapters[collateral].address
        elif len(localAssets) > 0 or localBalance[2] > 0:
            # Cash group asset rate reference set to local if it has assets
            assert factors[9][2][0] == freeCollateral.cTokenAdapters[local].address
        else:
            # This is the case during local liquidation if there are only cash assets in
            # the local currency, there is no way to liquidate in this way
            assert factors[9][2][0] == HexString(to_bytes(0, "bytes20"), "bytes")

        # isCalculation == false
        assert not factors[10]

    # Test Liquidation Factors
    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_bitmap_liquidation_factors(self, freeCollateral, accounts, local):
        # Setup undercollateralized account
        freeCollateral.mock.enableBitmapForAccount(accounts[0], local, START_TIME_TREF)
        freeCollateral.mock.setBalance(accounts[0], 1, -100e8, 200e8)
        freeCollateral.mock.setBalance(accounts[0], 2, 200e8, 100e8)
        freeCollateral.mock.setBalance(accounts[0], 3, -300e8, 0)
        freeCollateral.mock.setBalance(accounts[0], 4, 400e8, 0)

        # Leave this here to establish a large negative FC
        freeCollateral.mock.setifCashAsset(
            accounts[0], local, START_TIME_TREF + SECONDS_IN_DAY * 30, -10000e8
        )

        for c in range(0, 5):
            if c == local:
                continue
            self.validate_liquidation_factors(accounts[0], freeCollateral, local, c)

    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_array_liquidation_factors(self, freeCollateral, accounts, local):
        # This one should have a large negative balance to establish negative fc
        freeCollateral.mock.setBalance(accounts[0], 1, -100e8, 200e8)
        freeCollateral.mock.setBalance(accounts[0], 2, 200e8, 100e8)
        freeCollateral.mock.setBalance(accounts[0], 3, -300e8, 0)
        freeCollateral.mock.setBalance(accounts[0], 4, 400e8, 0)

        freeCollateral.mock.setPortfolio(
            accounts[0],
            [
                get_fcash_token(1, currencyId=1, notional=-10000e8),
                get_fcash_token(1, currencyId=3, notional=-10000e8),
            ],
        )

        for c in range(0, 5):
            if c == local:
                continue
            self.validate_liquidation_factors(accounts[0], freeCollateral, local, c)
