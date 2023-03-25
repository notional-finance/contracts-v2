import math

import brownie
import pytest
from brownie import accounts
from brownie.convert.datatypes import HexString, Wei
from brownie.network import Chain
from brownie.network.contract import Contract
from brownie.test import given, strategy
from tests.constants import (
    HAS_ASSET_DEBT,
    HAS_BOTH_DEBT,
    HAS_CASH_DEBT,
    MARKETS,
    SECONDS_IN_QUARTER,
    SETTLEMENT_DATE,
    START_TIME_TREF,
)
from tests.helpers import (
    currencies_list_to_active_currency_bytes,
    get_fcash_token,
    get_portfolio_array,
    setup_internal_mock,
    simulate_init_markets,
)

chain = Chain()


@pytest.mark.settlement
class TestSettlement:
    @pytest.fixture(scope="module", autouse=True)
    def mock(self, MockSettingsLib, SettleAssetsExternal, MockSettleAssets, accounts):
        settings = MockSettingsLib.deploy({"from": accounts[0]})
        SettleAssetsExternal.deploy({"from": accounts[0]})
        mock = MockSettleAssets.deploy(settings, {"from": accounts[0]})
        mock = Contract.from_abi(
            "mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0]
        )

        setup_internal_mock(mock)

        return mock

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def setup_portfolio(self, mock, isBitmap, currencyId, fCashValues):
        if isBitmap:
            mock.setAccountContext(
                accounts[1],
                (START_TIME_TREF, "0x00", 0, currencyId, HexString(0, "bytes18"), False),
            )
            mock.setBitmapAssets(
                accounts[1],
                [
                    get_fcash_token(i + 1, currencyId=currencyId, notional=n)
                    for (i, n) in enumerate(fCashValues)
                ],
            )
        else:
            state = mock.buildPortfolioState(accounts[1])
            for (i, n) in enumerate(fCashValues):
                state = mock.addAsset(state, currencyId, MARKETS[i], 1, n)

            mock.setPortfolio(accounts[1], state)

    @given(
        isBitmap=strategy("bool"),
        currencyId=strategy("uint", min_value=1, max_value=3),
        fCash=strategy("int", min_value=-1_000e8, max_value=1_000e8),
    )
    def test_settles_single_fcash(self, mock, accounts, isBitmap, currencyId, fCash):
        if abs(fCash) < 0.01e8:
            return

        self.setup_portfolio(mock, isBitmap, currencyId, [fCash])

        chain.mine(1, timestamp=SETTLEMENT_DATE + 1)
        simulate_init_markets(mock, currencyId)
        txn = mock.settleAccount(accounts[1])

        # check settlement rate is set
        assert len(txn.events["SetPrimeSettlementRate"]) == 1

        # should only have cash
        if isBitmap:
            portfolio = mock.getBitmapAssets(accounts[1])
        else:
            portfolio = mock.getPortfolio(accounts[1])
        assert len(portfolio) == 0

        balance = mock.getBalance(accounts[1], currencyId, txn.timestamp)
        pr = mock.getSettlementRate(currencyId, SETTLEMENT_DATE)
        underlying = mock.convertToUnderlying(pr, balance["cashBalance"])
        assert pytest.approx(underlying, abs=5) == fCash

        # account context should be set properly
        context = mock.getAccountContext(accounts[1])
        if fCash < 0 and not isBitmap:
            assert context["hasDebt"] == HAS_CASH_DEBT
        elif fCash < 0 and isBitmap:
            # The HAS_ASSET_DEBT flag does not get cleared for bitmaps
            assert context["hasDebt"] == HAS_BOTH_DEBT
        else:
            assert context["hasDebt"] == "0x00"

        if isBitmap:
            assert context["nextSettleTime"] == SETTLEMENT_DATE
        else:
            active_currencies = currencies_list_to_active_currency_bytes(
                [(currencyId, False, True)]
            )
            assert context["activeCurrencies"] == HexString(active_currencies, "bytes18")
            assert context["nextSettleTime"] == 0

    @given(fCash=strategy("int", min_value=-1_000e8, max_value=1_000e8))
    def test_settles_single_fcash_maturity_multiple_currency(self, mock, accounts, fCash):
        if abs(fCash) < 0.01e8:
            return

        state = mock.buildPortfolioState(accounts[1])
        state = mock.addAsset(state, 1, MARKETS[0], 1, fCash)
        state = mock.addAsset(state, 2, MARKETS[0], 1, fCash)
        state = mock.addAsset(state, 3, MARKETS[0], 1, fCash)
        mock.setPortfolio(accounts[1], state)

        chain.mine(1, timestamp=SETTLEMENT_DATE + 1)
        simulate_init_markets(mock, 1)
        simulate_init_markets(mock, 2)
        simulate_init_markets(mock, 3)
        txn = mock.settleAccount(accounts[1])

        # check settlement rate is set
        assert len(txn.events["SetPrimeSettlementRate"]) == 3
        # should only have cash
        assert len(mock.getPortfolio(accounts[1])) == 0

        for currencyId in [1, 2, 3]:
            balance = mock.getBalance(accounts[1], currencyId, txn.timestamp)
            pr = mock.getSettlementRate(currencyId, SETTLEMENT_DATE)
            underlying = mock.convertToUnderlying(pr, balance["cashBalance"])
            assert pytest.approx(underlying, abs=5) == fCash

        # account context should be set properly
        context = mock.getAccountContext(accounts[1])
        if fCash < 0:
            assert context["hasDebt"] == HAS_CASH_DEBT
        else:
            assert context["hasDebt"] == "0x00"

        active_currencies = currencies_list_to_active_currency_bytes(
            [(1, False, True), (2, False, True), (3, False, True)]
        )
        assert context["activeCurrencies"] == HexString(active_currencies, "bytes18")
        assert context["nextSettleTime"] == 0

    @given(
        isBitmap=strategy("bool"),
        currencyId=strategy("uint", min_value=1, max_value=3),
        fCash1=strategy("int", min_value=-1_000e8, max_value=1_000e8),
        fCash2=strategy("int", min_value=-1_000e8, max_value=1_000e8),
    )
    def test_settles_multiple_fcash_maturities_single_currency(
        self, mock, accounts, isBitmap, currencyId, fCash1, fCash2
    ):
        if abs(fCash1) < 0.01e8 or abs(fCash2) < 0.01e8:
            return

        # Setup two portfolios...
        state = mock.buildPortfolioState(accounts[2])
        state = mock.addAsset(state, currencyId, MARKETS[0], 1, -1_000e8)
        mock.setPortfolio(accounts[2], state)

        self.setup_portfolio(mock, isBitmap, currencyId, [fCash1, fCash2])

        chain.mine(1, timestamp=MARKETS[0] + 1)
        simulate_init_markets(mock, currencyId)
        txn = mock.settleAccount(accounts[2])

        # check settlement rate is set
        assert len(txn.events["SetPrimeSettlementRate"]) == 1

        # not settled yet
        if isBitmap:
            portfolio = mock.getBitmapAssets(accounts[1])
        else:
            portfolio = mock.getPortfolio(accounts[1])
        assert len(portfolio) == 2

        chain.mine(1, timestamp=MARKETS[1] + 1)
        txn = mock.settleAccount(accounts[1])
        assert len(txn.events["SetPrimeSettlementRate"]) == 1

        # Check that the first fCash asset accrues interest
        balance = mock.getBalance(accounts[1], currencyId, txn.timestamp)
        pr1 = mock.getSettlementRate(currencyId, MARKETS[0])
        pr2 = mock.getSettlementRate(currencyId, MARKETS[1])
        primeCashOne = mock.convertFromUnderlying(pr1, fCash1)
        if primeCashOne < 0:
            primeCashOne = math.floor(
                primeCashOne
                * (pr1["supplyFactor"] * pr2["debtFactor"])
                / (pr1["debtFactor"] * pr2["supplyFactor"])
            )
        primeCashTwo = mock.convertFromUnderlying(pr2, fCash2)
        assert (
            pytest.approx(balance["cashBalance"], rel=1e-10, abs=5) == primeCashOne + primeCashTwo
        )

        # account context should be set properly
        context = mock.getAccountContext(accounts[1])
        if balance["cashBalance"] < 0 and not isBitmap:
            assert context["hasDebt"] == HAS_CASH_DEBT
        elif balance["cashBalance"] < 0 and isBitmap:
            # HAS_ASSET_DEBT does not get cleared for bitmap accounts
            assert context["hasDebt"] == HAS_BOTH_DEBT
        elif isBitmap and (fCash1 < 0 or fCash2 < 0):
            # HAS_ASSET_DEBT does not get cleared for bitmap accounts
            assert context["hasDebt"] == HAS_ASSET_DEBT
        else:
            assert context["hasDebt"] == "0x00"

        if isBitmap:
            assert context["nextSettleTime"] == MARKETS[1]
        elif balance["cashBalance"] == 0:
            assert context["activeCurrencies"] == HexString(0, "bytes18")
            assert context["nextSettleTime"] == 0
        else:
            active_currencies = currencies_list_to_active_currency_bytes(
                [(currencyId, False, True)]
            )
            assert context["activeCurrencies"] == HexString(active_currencies, "bytes18")
            assert context["nextSettleTime"] == 0

    @given(
        isBitmap=strategy("bool"),
        currencyId=strategy("uint", min_value=1, max_value=3),
        fCash1=strategy("int", min_value=-1_000e8, max_value=1_000e8),
        fCash2=strategy("int", min_value=-1_000e8, max_value=1_000e8),
    )
    def test_does_not_settle_unmatured_fcash(
        self, mock, accounts, isBitmap, currencyId, fCash1, fCash2
    ):
        if abs(fCash1) < 0.001e8 or abs(fCash2) < 0.001e8:
            return

        self.setup_portfolio(mock, isBitmap, currencyId, [fCash1, fCash2])

        chain.mine(1, timestamp=MARKETS[0] + 1)
        simulate_init_markets(mock, currencyId)
        txn = mock.settleAccount(accounts[1])

        # check settlement rate is set
        assert len(txn.events["SetPrimeSettlementRate"]) == 1

        # only one asset settled
        if isBitmap:
            portfolio = mock.getBitmapAssets(accounts[1])
        else:
            portfolio = mock.getPortfolio(accounts[1])
        assert len(portfolio) == 1

        balance = mock.getBalance(accounts[1], currencyId, txn.timestamp)
        pr = mock.getSettlementRate(currencyId, SETTLEMENT_DATE)
        underlying = mock.convertToUnderlying(pr, balance["cashBalance"])
        assert pytest.approx(underlying, abs=5) == fCash1

        # account context should be set properly
        context = mock.getAccountContext(accounts[1])
        if balance["cashBalance"] < 0 and fCash2 < 0:
            assert context["hasDebt"] == HAS_BOTH_DEBT
        elif balance["cashBalance"] < 0 and not isBitmap:
            assert context["hasDebt"] == HAS_CASH_DEBT
        elif balance["cashBalance"] < 0 and isBitmap:
            assert context["hasDebt"] == HAS_BOTH_DEBT
        elif fCash2 < 0:
            assert context["hasDebt"] == HAS_ASSET_DEBT

        if isBitmap:
            assert context["nextSettleTime"] == MARKETS[0]
        else:
            active_currencies = currencies_list_to_active_currency_bytes([(currencyId, True, True)])
            assert context["activeCurrencies"] == HexString(active_currencies, "bytes18")
            assert context["nextSettleTime"] == MARKETS[1]
