import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
    get_interest_rate_curve,
    get_tref,
    initialize_environment,
    setup_residual_environment,
)
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


"""
Testing Matrix:

nToken State
1. cash, no liquid residuals, no ifCash residuals
2. no cash, no liquid residuals, no ifCash residuals
3. cash, no liquid residuals, negative ifCash residuals
4. no cash, no liquid residuals, negative ifCash residuals
5. cash, no liquid residuals, positive ifCash residuals
6. no cash, no liquid residuals, positive ifCash residuals

7. cash, liquid residuals (can't sell), no ifCash residuals
8. no cash, liquid residuals (can't sell), no ifCash residuals
9. cash, liquid residuals (can't sell), positive ifCash residuals
10. no cash, liquid residuals (can't sell), positive ifCash residuals
11. cash, liquid residuals (can't sell), negative ifCash residuals
12. no cash, liquid residuals (can't sell), negative ifCash residuals

13. cash, liquid residuals (can sell), no ifCash residuals
14. no cash, liquid residuals (can sell), no ifCash residuals
15. cash, liquid residuals (can sell), positive ifCash residuals
16. no cash, liquid residuals (can sell), positive ifCash residuals
17. cash, liquid residuals (can sell), negative ifCash residuals
18. no cash, liquid residuals (can sell), negative ifCash residuals

Results:
[User Option, State]
[(all), 1]: cash share
[(all), 2]: revert

1. batchBalance [True, False] sellfCash, no residuals
2. nTokenRedeem [True, False] sellfCash, no residuals
(3-6): cash share, tokens withdrawn
(7-12): revert
(13-18): cash share, tokens withdrawn, residuals sold

3. nTokenRedeem [False, False] keep fCash, no residuals
(3-6): cash only (discount)
(7-18): revert

4. nTokenRedeem [False, True] keep fCash, accept residuals
(3-18): cash, liquid fCash assets, ifCash assets (no discount)

5. nTokenRedeem [True, True] sellfCash, accept residuals
(3-6): cash, ifCash assets (no discount)
(7-12): cash, liquid fCash assets, ifCash assets (no discount)
(13-18): cash, ifCash assets (no discount)
"""

class RedeemChecker():

    def find(self, events, maturity):
        f = [ e for e in events if e['maturity'] == maturity]
        if len(f) == 0:
            return None
        elif len(f) > 1:
            raise Exception("Multiple maturities")
        else:
            return f[0]

    def __init__(self, environment, account, currencyId):
        self.environment = environment
        self.account = account
        self.currencyId = currencyId

    def __enter__(self):
        nTokenAddress = self.environment.notional.nTokenAddress(self.currencyId)
        (nTokenPortfolio, ifCashAssets) = self.environment.notional.getNTokenPortfolio(nTokenAddress)
        markets = self.environment.notional.getActiveMarkets(self.currencyId)
        totalSupply = self.environment.nToken[self.currencyId].totalSupply()

        self.context = {
            'totalSupply': totalSupply,
            'balances': self.environment.notional.getAccountBalance(self.currencyId, self.account),
            'portfolio': self.environment.notional.getAccountPortfolio(self.account),
            'nTokenPortfolio': nTokenPortfolio,
            'ifCashAssets': ifCashAssets,
            'markets': markets
        }

        return self.context

    def __exit__(self, *_):
        pass
        # decoded = decode_events(self.environment, self.context['txn'])
        # grouped = group_events(decoded)

        # nTokenAddress = self.environment.notional.nTokenAddress(self.currencyId)
        # (nTokenPortfolioAfter, ifCashAssetsAfter) = self.environment.notional.getNTokenPortfolio(nTokenAddress)

        # totalSupplyAfter = self.environment.nToken[self.currencyId].totalSupply()
        # balancesAfter = self.environment.notional.getAccountBalance(self.currencyId, self.account)
        # portfolioAfter = self.environment.notional.getAccountPortfolio(self.account)
        # marketsAfter = self.environment.notional.getActiveMarkets(self.currencyId)

        # assert len(grouped['Redeem nToken']) == 1
        # redeem = grouped['Redeem nToken'][0]
        # assert redeem['account'] == self.account.address
        # assert redeem['nTokensRedeemed'] == self.context['redeemAmount']
        # assert redeem['nTokensRedeemed'] == self.context['totalSupply'] - totalSupplyAfter
        # assert redeem['nTokensRedeemed'] == self.context['balances']['nTokenBalance'] - balancesAfter['nTokenBalance']
        # # assert redeem['primeCashToAccount'] == balancesAfter['cashBalance'] - self.context['balances']['cashBalance']

        # liquidity = grouped['nToken Remove Liquidity']
        # transfers = grouped['nToken Residual Transfer']
        # sellAssets = grouped['Buy fCash [nToken]'] + grouped['Sell fCash [nToken]']

        # for (i, a) in enumerate(ifCashAssetsAfter):
        #     # Check that fCash burned equals what is emitted
        #     # fCash burned + residual transfer + fCash sold
        #     maturity = a[1]
        #     l = self.find(liquidity, maturity)
        #     t = self.find(transfers, maturity)
        #     s = self.find(sellAssets, maturity)
        #     marketBefore = [m for m in self.context['markets'] if m[1] == maturity]
        #     marketAfter = [m for m in marketsAfter if m[1] == maturity]

        #     transfer = t['fCash'] if t is not None else 0
        #     fCashSold = s['fCash'] if s is not None else 0
        #     # Selling fCash here always nets off the transfer
        #     if s and t:
        #         assert pytest.approx(t['fCash'] - s['fCash'], abs=1) == 0

        #     if len(marketBefore) > 0:
        #         # Check that total liquidity and fCash is equal
        #         assert marketBefore[0][1] == l['maturity']
        #         assert marketBefore[0][2] + l['fCash'] + transfer - fCashSold == marketAfter[0][2]
        #         # Liquidity tokens are equal
        #         lt = [lt for lt in nTokenPortfolioAfter if lt[1] == maturity]
        #         assert lt[0][3] == marketAfter[0][4]
        #         assert l['account'] == nTokenAddress

        #     # Check that fCash assets net off
        #     assetBefore = [f for f in self.context['ifCashAssets'] if f[1] == maturity][0]
        #     assetAfter = [f for f in ifCashAssetsAfter if f[1] == maturity][0]
        #     if l:
        #         # If liquidity is burned, then this should net off
        #         assert assetBefore[3] - l['fCash'] == assetAfter[3]
        #     else:
        #         # If fCash is transferred then this should net off (for ifCash assets)
        #         assert assetBefore[3] - transfer == assetAfter[3]

def test_redeem_tokens_and_sell_fcash(environment, accounts):
    currencyId = 2
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    with EventChecker(environment, 'Redeem nToken') as e:
        txn = environment.notional.nTokenRedeem(
            accounts[0].address, currencyId, 1e8, True, False, {"from": accounts[0]}
        )
        e['txn'] = txn

    # Assert that no assets in portfolio
    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0

    check_system_invariants(environment, accounts)

def test_redeem_tokens_and_save_assets_portfolio(environment, accounts):
    currencyId = 2

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    with EventChecker(environment, 'Redeem nToken', nTokensRedeemed=1e8) as c:
        c['txn'] = environment.notional.nTokenRedeem(
            accounts[0].address, currencyId, 1e8, False, True, {"from": accounts[0]}
        )

    portfolio = environment.notional.getAccountPortfolio(accounts[0])
    for asset in portfolio:
        # Should be a net borrower because of lending
        assert asset[3] < 0

    check_system_invariants(environment, accounts)


def test_redeem_tokens_and_save_assets_settle(environment, accounts):
    currencyId = 2

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 10e8, "maxSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    environment.nToken[currencyId].transfer(accounts[1], 10e8, {"from": accounts[0]})

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    environment.notional.initializeMarkets(3, False)
    # Check invariants here to ensure that the account gets settled
    check_system_invariants(environment, accounts)

    with EventChecker(environment, 'Redeem nToken', nTokensRedeemed=1e8) as c:
        txn = environment.notional.nTokenRedeem(
            accounts[1].address, currencyId, 1e8, False, True, {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    assert context[1] == "0x02"

    check_system_invariants(environment, accounts)

def test_redeem_tokens_and_save_assets_bitmap(environment, accounts):
    currencyId = 2
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 10e8, "maxSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=300e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.enableBitmapCurrency(currencyId, {"from": accounts[1]})
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    portfolioBefore = environment.notional.getAccountPortfolio(accounts[1])

    environment.nToken[currencyId].transfer(accounts[1], 10e8, {"from": accounts[0]})

    with EventChecker(environment, 'Redeem nToken', nTokensRedeemed=1e8) as c:
        c['txn'] = environment.notional.nTokenRedeem(
            accounts[1].address, currencyId, 1e8, False, True, {"from": accounts[1]}
        )

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 2
    assert portfolio[0][1] == portfolioBefore[0][1]
    assert portfolio[0][3] > portfolioBefore[0][3]
    assert portfolio[1][1] == portfolioBefore[1][1]
    assert portfolio[1][3] < portfolioBefore[1][3]

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_batch_balance_action(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 98_000e8 * environment.primeCashScalars["DAI"]
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0

    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()
    action = get_balance_action(2, "RedeemNToken", depositActionAmount=redeemAmount)

    if not canSellResiduals and marketResiduals:
        with brownie.reverts():
            environment.notional.nTokenRedeem.call(
                accounts[2].address, currencyId, redeemAmount, True, False, {"from": accounts[2]}
            )
    else:
        with EventChecker(environment, 'Redeem nToken', nTokensRedeemed=redeemAmount) as c:
            c['txn'] = environment.notional.batchBalanceAction(
                accounts[2].address, [action], {"from": accounts[2]}
            )

    # Account should have redeemed around the ifCash residual
    portfolio = environment.notional.getAccountPortfolio(accounts[2])
    assert len(portfolio) == 0

    # Test for PV of account[2] assets relative to redeem
    (cash, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    cashRatio = cash / nTokenPV
    supplyRatio = redeemAmount / totalSupply

    if residualType == 0 and not marketResiduals:
        # In this scenario (with no residuals anywhere) valuation is at par
        assert pytest.approx(cashRatio, rel=1e-9) == supplyRatio
    else:
        assert cashRatio < supplyRatio

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_sell_fcash_no_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 98_000e8 * environment.primeCashScalars["DAI"]
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0

    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    if not canSellResiduals and marketResiduals:
        # If residual sales fail then this must revert
        with brownie.reverts():
            environment.notional.nTokenRedeem.call(
                accounts[2].address, currencyId, redeemAmount, True, False, {"from": accounts[2]}
            )
    else:
        with EventChecker(environment, 'Redeem nToken', nTokensRedeemed=redeemAmount) as c:
            c['txn'] = environment.notional.nTokenRedeem(
                accounts[2].address, currencyId, redeemAmount, True, False, {"from": accounts[2]}
            )

    # Account should have redeemed around the ifCash residual
    portfolio = environment.notional.getAccountPortfolio(accounts[2])
    assert len(portfolio) == 0

    # Test for PV of account[2] assets relative to redeem
    (cash, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    cashRatio = cash / nTokenPV
    supplyRatio = redeemAmount / totalSupply

    if residualType == 0 and not marketResiduals:
        # In this scenario (with no residuals anywhere) valuation is at par
        assert pytest.approx(cashRatio, rel=1e-9) == supplyRatio
    else:
        assert cashRatio < supplyRatio

    check_system_invariants(environment, accounts)

@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_keep_assets_no_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 50_000e8 * environment.primeCashScalars["DAI"]
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0

    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    if not marketResiduals:
        with EventChecker(environment, 'Redeem nToken', nTokensRedeemed = redeemAmount) as c:
            c['txn'] =environment.notional.nTokenRedeem(
                accounts[2].address, currencyId, redeemAmount, False, False, {"from": accounts[2]}
            )

        # Should have fCash assets for each liquid market
        portfolio = environment.notional.getAccountPortfolio(accounts[2])
        assert len(portfolio) == 0

        (cash, _, _) = environment.notional.getAccountBalance(2, accounts[2])
        cashRatio = cash / nTokenPV
        supplyRatio = redeemAmount / totalSupply

        if residualType == 0:
            # In this scenario (with no residuals anywhere) valuation is at par
            assert pytest.approx(cashRatio, rel=1e-9) == supplyRatio
        else:
            assert cashRatio < supplyRatio
    else:
        # If there are any market residuals this version will fail
        with brownie.reverts("Residuals"):
            environment.notional.nTokenRedeem(
                accounts[2].address, currencyId, 50_000e8, False, False, {"from": accounts[2]}
            )

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_keep_assets_accept_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 50_000e8 * environment.primeCashScalars["DAI"]
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0
    blockTime = chain.time()
    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    with EventChecker(environment, 'Redeem nToken',
        nTokensRedeemed=redeemAmount,
        residuals=lambda x: len(x) == 0 if residualType == 0 and not marketResiduals else len(x) > 0
    ) as c:
        c['txn'] = environment.notional.nTokenRedeem(
            accounts[2].address, currencyId, redeemAmount, False, True, {"from": accounts[2]}
        )

    # Should have fCash assets for each liquid market and the ifCash asset
    portfolio = environment.notional.getAccountPortfolio(accounts[2])

    if residualType == 0:
        if marketResiduals:
            assert len(portfolio) == 3
            assert portfolio[0][1] == ifCashAssets[0][1]
            assert portfolio[1][1] == ifCashAssets[1][1]
            assert portfolio[2][1] == ifCashAssets[2][1]
        else:
            assert len(portfolio) == 0
    else:
        if marketResiduals:
            assert len(portfolio) == 4
            assert portfolio[0][1] == ifCashAssets[0][1]
            assert portfolio[1][1] == ifCashAssets[1][1]
            assert portfolio[2][1] == ifCashAssets[2][1]
            assert portfolio[3][1] == ifCashAssets[3][1]
        else:
            # Only the ifCash asset here
            # We can get off by one errors here due to the nature of the
            # calculation when we approximate the fCashClaim & netfCash
            if len(portfolio) > 1:
                # Filter out anything that is dust
                portfolio = list(filter(lambda x: abs(x[3]) > 1, portfolio))

            assert len(portfolio) == 1
            assert portfolio[0][1] == ifCashAssets[2][1]

    (valuation, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    for a in portfolio:
        # This is in asset cash terms
        valuation += environment.notional.getPresentfCashValue(2, a[1], a[3], blockTime, False) * 50
    valuationRatio = valuation / nTokenPV
    supplyRatio = redeemAmount / totalSupply

    # assert that valuation is par to the nToken PV
    assert pytest.approx(valuationRatio, abs=100) == supplyRatio

    check_system_invariants(environment, accounts)


@given(
    residualType=strategy("uint8", min_value=0, max_value=2),
    marketResiduals=strategy("bool"),
    canSellResiduals=strategy("bool"),
)
def test_redeem_ntoken_sell_assets_accept_residuals(
    environment, accounts, residualType, marketResiduals, canSellResiduals
):
    currencyId = 2
    redeemAmount = 98_000e8 * environment.primeCashScalars["DAI"]
    setup_residual_environment(
        environment, accounts, residualType, marketResiduals, canSellResiduals
    )
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (_, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # Environment now has residuals, transfer some nTokens to clean account and attempt to redeem
    environment.nToken[currencyId].transfer(accounts[2], redeemAmount, {"from": accounts[0]})
    assert len(environment.notional.getAccountPortfolio(accounts[2])) == 0
    blockTime = chain.time()
    nTokenPV = environment.notional.nTokenPresentValueAssetDenominated(currencyId)
    totalSupply = environment.nToken[currencyId].totalSupply()

    with EventChecker(environment, 'Redeem nToken', nTokensRedeemed=redeemAmount) as c:
        c['txn'] = environment.notional.nTokenRedeem(
            accounts[2].address, currencyId, redeemAmount, True, True, {"from": accounts[2]}
        )

    portfolio = environment.notional.getAccountPortfolio(accounts[2])

    (valuation, _, _) = environment.notional.getAccountBalance(2, accounts[2])
    for a in portfolio:
        valuation += environment.notional.getPresentfCashValue(2, a[1], a[3], blockTime, False)
    valuationRatio = valuation / nTokenPV
    supplyRatio = redeemAmount / totalSupply

    # 9 month fCash maturity
    ifCashMaturity = get_tref(chain.time()) + SECONDS_IN_QUARTER * 3
    if residualType == 0:
        if not marketResiduals or canSellResiduals:
            # No ifCash residuals so no assets
            assert len(portfolio) == 0
        else:
            # Some fCash residuals sold but not all
            assert len(portfolio) > 0 and len(portfolio) < 4
            # No ifCash assets in portfolio
            assert len(list(filter(lambda x: x[1] == ifCashMaturity, portfolio))) == 0
    else:
        if not marketResiduals or canSellResiduals:
            # We can get off by one errors here due to the nature of the
            # calculation when we approximate the fCashClaim & netfCash
            if len(portfolio) > 1:
                # Filter out anything that is dust
                portfolio = list(filter(lambda x: abs(x[3]) > 1, portfolio))

            # Only the ifCash asset is in the portfolio
            assert len(portfolio) == 1
            assert portfolio[0][1] == ifCashAssets[2][1]
        else:
            # Some fCash residuals sold but not all
            assert len(portfolio) > 0 and len(portfolio) <= 4
            # Holding ifCash assets in portfolio
            assert len(list(filter(lambda x: x[1] == ifCashMaturity, portfolio))) == 1

    if marketResiduals and canSellResiduals:
        assert valuationRatio < supplyRatio
    else:
        assert pytest.approx(valuationRatio, abs=100) == supplyRatio

    check_system_invariants(environment, accounts)

def test_redeem_tokens_and_sell_fcash_zero_notional(environment, accounts):
    # This unit test is here to test a bug where markets were skipped during the sellfCash portion
    # of redeeming nTokens
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the two year markets
    cashGroup[0] = 4
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.2e8, 0.2e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2, 3, 4], [get_interest_rate_curve()] * 4
    )
    environment.notional.updateInitializationParameters(
        currencyId, [0] * 4, [0.5e9, 0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    for (cid, _) in environment.nToken.items():
        try:
            environment.notional.initializeMarkets(cid, False)
        except Exception:
            pass

    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=10e18)
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            # This leaves a positive residual
            {"tradeActionType": "Borrow", "marketIndex": 3, "notional": 1e4, "maxSlippage": 0},
            # This leaves a negative residual
            {"tradeActionType": "Lend", "marketIndex": 4, "notional": 1e4, "minSlippage": 0},
        ],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, action], {"from": accounts[1], "value": 10e18}
    )

    # Now settle the markets, should be some residual
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    for (cid, _) in environment.nToken.items():
        try:
            environment.notional.initializeMarkets(cid, False)
        except Exception:
            pass

    # Leaves some more residual
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 3, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 4, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=500e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, action], {"from": accounts[1], "value": 10e18}
    )

    # Need to ensure that no residual assets are left behind
    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0
    with EventChecker(
        environment, 'Redeem nToken',
        nTokensRedeemed=1e8, 
        residuals=lambda x: len(x) > 0,
        maturities=[get_tref(chain.time()) + 8 * SECONDS_IN_QUARTER]
    ) as c:
        c['txn'] = environment.notional.nTokenRedeem(
            accounts[0].address, currencyId, 1e8, True, False, {"from": accounts[0]}
        )

    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0
    check_system_invariants(environment, accounts)
