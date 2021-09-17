import logging
import math
import random

import pytest
from brownie.convert.datatypes import HexString, Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from hypothesis import settings
from tests.constants import (
    HAS_ASSET_DEBT,
    HAS_CASH_DEBT,
    SECONDS_IN_DAY,
    SETTLEMENT_DATE,
    START_TIME,
    START_TIME_TREF,
)
from tests.helpers import (
    get_cash_group_with_max_markets,
    get_eth_rate_mapping,
    get_fcash_token,
    get_market_curve,
    get_portfolio_array,
)

LOGGER = logging.getLogger(__name__)
chain = Chain()

"""
Account Context:
    nextSettleTime:
        in past, revert
        else, proceed
"""

ethRates = {1: 1e18, 2: 0.01e18, 3: 0.011e18, 4: 10e18}

underlyingDecimals = {1: 18, 2: 18, 3: 6, 4: 8}

cTokenRates = {
    1: Wei(200000000000000000000000000),
    2: Wei(210000000000000000000000000),
    3: Wei(220000000000000),
    4: Wei(23000000000000000),
}

nTokenAddress = {
    1: HexString(1, "bytes20"),
    2: HexString(2, "bytes20"),
    3: HexString(3, "bytes20"),
    4: HexString(4, "bytes20"),
}

nTokenTotalSupply = {
    1: Wei(10_000_000e8),
    2: Wei(20_000_000e8),
    3: Wei(30_000_000e8),
    4: Wei(40_000_000e8),
}

nTokenCashBalance = {
    1: Wei(50_000_000e8),
    2: Wei(60_000_000e8),
    3: Wei(70_000_000e8),
    4: Wei(80_000_000e8),
}

nTokenParameters = {1: (85, 90), 2: (86, 91), 3: (80, 88), 4: (75, 80)}

bufferHaircutDiscount = {1: (130, 70, 105), 2: (105, 95, 106), 3: (110, 90, 107), 4: (150, 50, 102)}


@pytest.mark.valuation
class TestFreeCollateral:
    markets = {}
    cashGroups = {}
    cTokenAdapters = {}

    @pytest.fixture(scope="module", autouse=True)
    def ethAggregators(self, MockAggregator, accounts):
        return [
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
            MockAggregator.deploy(18, {"from": accounts[0]}),
        ]

    @pytest.fixture(scope="module", autouse=True)
    def freeCollateral(
        self,
        MockValuationLib,
        MockFreeCollateral,
        MockCToken,
        cTokenAggregator,
        ethAggregators,
        accounts,
    ):
        MockValuationLib.deploy({"from": accounts[0]})
        fc = accounts[0].deploy(MockFreeCollateral)
        for i in range(1, 5):
            cToken = accounts[0].deploy(MockCToken, 8)
            cToken.setAnswer(cTokenRates[i])
            self.cTokenAdapters[i] = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})

            fc.setAssetRateMapping(i, (self.cTokenAdapters[i].address, underlyingDecimals[i]))
            self.cashGroups[i] = get_cash_group_with_max_markets(3)
            fc.setCashGroup(i, self.cashGroups[i])

            ethAggregators[i - 1].setAnswer(ethRates[i])
            fc.setETHRateMapping(
                i,
                get_eth_rate_mapping(
                    ethAggregators[i - 1],
                    buffer=bufferHaircutDiscount[i][0],
                    haircut=bufferHaircutDiscount[i][1],
                    discount=bufferHaircutDiscount[i][2],
                ),
            )

            fc.setNTokenValue(
                i,
                nTokenAddress[i],
                nTokenTotalSupply[i],
                nTokenCashBalance[i],
                nTokenParameters[i][0],
                nTokenParameters[i][1],
            )

            # TODO: change the market curve...
            self.markets[i] = get_market_curve(3, "flat")
            for m in self.markets[i]:
                fc.setMarketStorage(i, SETTLEMENT_DATE, m)

        chain.mine(1, timestamp=START_TIME)

        return fc

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def calculate_to_underlying(self, currency, balance):
        return math.trunc(
            (balance * cTokenRates[currency] * Wei(1e8))
            / (Wei(1e18) * Wei(10 ** underlyingDecimals[currency]))
        )

    def calculate_from_underlying(self, currency, balance):
        return math.trunc(
            (balance * Wei(1e18) * Wei(10 ** underlyingDecimals[currency]))
            / (cTokenRates[currency] * Wei(1e8))
        )

    def calculate_to_eth(self, currency, underlying):
        multiple = (
            bufferHaircutDiscount[currency][1]
            if underlying > 0
            else bufferHaircutDiscount[currency][0]
        )
        return math.trunc(
            (underlying * ethRates[currency] * Wei(multiple)) / (Wei(1e18) * Wei(100))
        )

    def calculate_ntoken_to_asset(self, currency, nToken):
        return math.trunc(
            (nToken * nTokenCashBalance[currency] * nTokenParameters[currency][0])
            / (nTokenTotalSupply[currency] * 100)
        )

    def get_fc_and_net_local(self, freeCollateral, accounts):
        txn = freeCollateral.testFreeCollateral(accounts[0], START_TIME)
        fc = txn.events["FreeCollateralResult"][0]["fc"]
        netLocal = txn.events["FreeCollateralResult"][0]["netLocal"]

        return (fc, netLocal, txn)

    # Test Single Free Collateral Components
    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        balance=strategy("uint", min_value=0, max_value=100_000_000e8),
    )
    def test_positive_cash_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.setBalance(accounts[0], currency, balance, 0)
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        assert netLocal[0] == balance

        underlying = self.calculate_to_underlying(currency, balance)
        assert pytest.approx(underlying, abs=1) == freeCollateral.convertToUnderlying(
            currency, balance
        )

        ethFC = self.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        balance=strategy("int", min_value=-100_000_000e8, max_value=0),
    )
    def test_negative_cash_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.setBalance(accounts[0], currency, balance, 0)
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        assert netLocal[0] == balance

        underlying = self.calculate_to_underlying(currency, balance)
        assert pytest.approx(underlying, abs=1) == freeCollateral.convertToUnderlying(
            currency, balance
        )

        ethFC = self.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    # nToken Balance
    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        balance=strategy("uint", min_value=0, max_value=10_000_000e8),
    )
    def test_ntoken_balance(self, freeCollateral, accounts, currency, balance):
        freeCollateral.setBalance(accounts[0], currency, 0, balance)
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        nTokenLocalAsset = self.calculate_ntoken_to_asset(currency, balance)

        assert pytest.approx(netLocal[0], abs=1) == nTokenLocalAsset

        underlying = self.calculate_to_underlying(currency, nTokenLocalAsset)
        ethFC = self.calculate_to_eth(currency, underlying)
        assert pytest.approx(fc, abs=1) == ethFC

    # Portfolio Valuation
    @given(
        numAssets=strategy("uint", min_value=0, max_value=6),
        numCurrencies=strategy("uint", min_value=1, max_value=4),
    )
    @settings(max_examples=10)
    def test_portfolio_valuation(self, freeCollateral, accounts, numAssets, numCurrencies):
        # TODO: set additional balances...
        cashGroups = []
        for i in range(1, numCurrencies + 1):
            cashGroups.append(self.cashGroups[i])

        assets = get_portfolio_array(numAssets, cashGroups, sorted=True)
        LOGGER.info("got assets {}, {}".format(numAssets, numCurrencies))
        freeCollateral.setPortfolio(accounts[0], assets)
        LOGGER.info("set portfolio {}".format(assets))

        i = 0
        netLocalIndex = 0
        ethFC = 0
        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)
        LOGGER.info("got fc")
        while i < len(assets):
            LOGGER.info("inside loop {}, {}".format(i, len(assets)))
            currency = assets[i][0]
            (assetCashValue, i) = freeCollateral.getNetCashGroupValue(assets, START_TIME, i)
            LOGGER.info("loop at {}, {}".format(i, netLocalIndex))

            # Check that net local is correct on each loop
            assert netLocal[netLocalIndex] == assetCashValue
            netLocalIndex += 1

            underlying = self.calculate_to_underlying(currency, assetCashValue)
            ethFC += self.calculate_to_eth(currency, underlying)

            if i < len(assets):
                # Assert that the currency id is split
                assert assets[i - 1][0] < assets[i][0]
            elif i == len(assets):
                # i == len(assets) then we break, reached end
                break
            else:
                # Should not reach this condition
                assert False

        assert pytest.approx(fc, abs=1) == ethFC
        LOGGER.info("end loop {}, {}".format(fc, ethFC))
        # Seems like some issue with reverting chain?

    @given(
        numAssets=strategy("uint", min_value=0, max_value=10),
        currency=strategy("uint", min_value=1, max_value=4),
    )
    def test_bitmap_valuation(self, freeCollateral, accounts, numAssets, currency):
        # TODO: set additional balances...

        freeCollateral.enableBitmapForAccount(accounts[0], currency, START_TIME_TREF)
        for i in range(0, numAssets):
            bitNum = random.randint(1, 130)
            maturity = freeCollateral.getMaturityFromBitNum(START_TIME_TREF, bitNum)
            notional = random.randint(-500_000e8, 500_000e8)
            freeCollateral.setifCashAsset(accounts[0], currency, maturity, notional)

        (_, _, portfolio) = freeCollateral.getAccount(accounts[0])

        presentValue = 0
        for asset in portfolio:
            presentValue += freeCollateral.getRiskAdjustedPresentfCashValue(asset, START_TIME_TREF)

        (fc, netLocal, _) = self.get_fc_and_net_local(freeCollateral, accounts)

        netLocalAsset = self.calculate_from_underlying(currency, presentValue)
        assert pytest.approx(netLocal[0], abs=1) == netLocalAsset

        ethFC = self.calculate_to_eth(currency, presentValue)
        assert pytest.approx(fc, abs=20) == ethFC

    # Test Update Context, these tests also check that FC does NOT update the
    # method if not required.
    # Bitmap Has Asset Debt
    # Bitmap Has Cash Debt
    # Array Has Cash Debt
    def test_bitmap_has_asset_debt(self, freeCollateral, accounts):
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
        txn = freeCollateral.getLiquidationFactors(account, START_TIME_TREF, local, collateral)
        factors = txn.events["Liquidation"][0]["factors"]
        (_, balances, portfolio) = freeCollateral.getAccount(account)

        localBalance = list(filter(lambda x: x[0] == local, balances))[0]
        localAssets = list(filter(lambda x: x[0] == local, portfolio))
        portfolioValue = 0
        for asset in localAssets:
            portfolioValue += freeCollateral.getRiskAdjustedPresentfCashValue(
                asset, START_TIME_TREF
            )

        localAssetAvailable = (
            localBalance[1]
            + self.calculate_ntoken_to_asset(local, localBalance[2])
            + self.calculate_from_underlying(local, portfolioValue)
        )
        nTokenHaircutAssetValue = self.calculate_ntoken_to_asset(local, localBalance[2])

        collateralAssetAvailable = 0
        if collateral > 0:
            collateralBalance = list(filter(lambda x: x[0] == collateral, balances))[0]
            collateralAssets = list(filter(lambda x: x[0] == collateral, portfolio))
            nTokenHaircutAssetValue = self.calculate_ntoken_to_asset(
                collateral, collateralBalance[2]
            )

            portfolioValue = 0
            for asset in collateralAssets:
                portfolioValue += freeCollateral.getRiskAdjustedPresentfCashValue(
                    asset, START_TIME_TREF
                )

            collateralAssetAvailable = (
                collateralBalance[1]
                + self.calculate_ntoken_to_asset(collateral, collateralBalance[2])
                + self.calculate_from_underlying(collateral, portfolioValue)
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
            assert int(factors[5].hex()[6:8], 16) == nTokenParameters[collateral][0]
            assert int(factors[5].hex()[0:2], 16) == nTokenParameters[collateral][1]
        elif collateral == 0 and localBalance[2] > 0:
            assert int(factors[5].hex()[6:8], 16) == nTokenParameters[local][0]
            assert int(factors[5].hex()[0:2], 16) == nTokenParameters[local][1]
        else:
            assert factors[5] == "0x000000000000"

        # Local ETH Rate
        assert factors[6][0] == 1e18  # Rate Decimals
        assert factors[6][1] == ethRates[local]  # Rate
        assert factors[6][2:] == bufferHaircutDiscount[local]
        # Collateral ETH Rate
        if collateral > 0:
            assert factors[7][0] == 1e18  # Rate Decimals
            assert factors[7][1] == ethRates[collateral]  # Rate
            assert factors[7][2:] == bufferHaircutDiscount[collateral]
        else:
            assert factors[7] == (0, 0, 0, 0, 0)

        # Local Asset Rate
        assert factors[8] == (
            self.cTokenAdapters[local].address,
            cTokenRates[local],
            10 ** underlyingDecimals[local],
        )
        # Cash Group Parameters
        # Cash group will be loaded if there are assets or nTokens
        if collateral == 0 and (len(localAssets) > 0 or localBalance[2] > 0):
            assert factors[9][0] == local
        elif collateral > 0 and (len(collateralAssets) > 0 or collateralBalance[2] > 0):
            assert factors[9][0] == collateral
        else:
            assert factors[9][0] == 0

        # Cash group asset rate reference (must be set regardless)
        assert (
            factors[9][2][0] == self.cTokenAdapters[local].address
            if collateral == 0
            else self.cTokenAdapters[collateral].address
        )
        # isCalculation == false
        assert not factors[10]

    # Test Liquidation Factors
    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_bitmap_liquidation_factors(self, freeCollateral, accounts, local):
        # Setup undercollateralized account
        freeCollateral.enableBitmapForAccount(accounts[0], local, START_TIME_TREF)
        freeCollateral.setBalance(accounts[0], 1, -100e8, 200e8)
        freeCollateral.setBalance(accounts[0], 2, 200e8, 100e8)
        freeCollateral.setBalance(accounts[0], 3, -300e8, 0)
        freeCollateral.setBalance(accounts[0], 4, 400e8, 0)

        # Leave this here to establish a large negative FC
        freeCollateral.setifCashAsset(
            accounts[0], local, START_TIME_TREF + SECONDS_IN_DAY * 30, -10000e8
        )

        for c in range(0, 5):
            if c == local:
                continue
            self.validate_liquidation_factors(accounts[0], freeCollateral, local, c)

    @given(local=strategy("uint", min_value=1, max_value=4))
    def test_array_liquidation_factors(self, freeCollateral, accounts, local):
        # This one should have a large negative balance to establish negative fc
        freeCollateral.setBalance(accounts[0], 1, -100e8, 200e8)
        freeCollateral.setBalance(accounts[0], 2, 200e8, 100e8)
        freeCollateral.setBalance(accounts[0], 3, -300e8, 0)
        freeCollateral.setBalance(accounts[0], 4, 400e8, 0)

        freeCollateral.setPortfolio(
            accounts[0],
            [
                get_fcash_token(1, currency=1, notional=-10000e8),
                get_fcash_token(1, currency=3, notional=-10000e8),
            ],
        )

        for c in range(0, 5):
            if c == local:
                continue
            self.validate_liquidation_factors(accounts[0], freeCollateral, local, c)
