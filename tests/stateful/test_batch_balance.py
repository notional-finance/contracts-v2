import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.constants import HAS_CASH_DEBT
from tests.helpers import active_currencies_to_list, get_balance_action, initialize_environment
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_fails_on_unordered_currencies(environment, accounts):
    with brownie.reverts("Unsorted actions"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(3, "DepositUnderlying", depositActionAmount=int(100e8)),
                get_balance_action(2, "DepositUnderlying", depositActionAmount=int(100e8)),
            ],
        )

    with brownie.reverts("Unsorted actions"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(2, "DepositUnderlying", depositActionAmount=100e8),
                get_balance_action(2, "DepositUnderlying", depositActionAmount=100e8),
            ],
        )


def test_fails_on_invalid_currencies(environment, accounts):
    with brownie.reverts():
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(2, "DepositAsset", depositActionAmount=100e8),
                get_balance_action(5, "DepositAsset", depositActionAmount=100e8),
            ],
        )


def test_fails_on_unauthorized_caller(environment, accounts):
    with brownie.reverts():
        environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(2, "DepositAsset", depositActionAmount=100e8),
                get_balance_action(3, "DepositAsset", depositActionAmount=100e8),
            ],
            {"from": accounts[0]},
        )

def test_deposit_deprecated_asset_batch(environment, accounts):
    with EventChecker(
        environment, 'Account Action',
        account=accounts[1].address,
        netCash=lambda x: x[2] == environment.approxPrimeCash('DAI', 100e18) and
            x[3] == environment.approxPrimeCash('USDC', 100e6)
    ) as c:
        txn = environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(2, "DepositAsset", depositActionAmount=5000e8),
                get_balance_action(3, "DepositAsset", depositActionAmount=5000e8),
            ],
            {"from": accounts[1]},
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert environment.approxInternal("DAI", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert environment.approxInternal("USDC", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_underlying_batch(environment, accounts):
    with EventChecker(
        environment, 'Account Action',
        account=accounts[1].address,
        netCash=lambda x: x[2] == environment.approxPrimeCash('DAI', 100e18) and
            x[3] == environment.approxPrimeCash('USDC', 100e6)
    ) as c:
        txn = environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(2, "DepositUnderlying", depositActionAmount=100e18),
                get_balance_action(3, "DepositUnderlying", depositActionAmount=100e6),
            ],
            {"from": accounts[1]},
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert environment.approxInternal("DAI", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert environment.approxInternal("USDC", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


@given(useUnderlying=strategy("bool"))
def test_deposit_and_mint_ntoken(environment, accounts, useUnderlying):
    with EventChecker(environment, "Mint nToken") as e:
        if useUnderlying:
            txn = environment.notional.batchBalanceAction(
                accounts[1],
                [
                    get_balance_action(2, "DepositUnderlyingAndMintNToken", depositActionAmount=100e18),
                    get_balance_action(3, "DepositUnderlyingAndMintNToken", depositActionAmount=100e6),
                ],
                {"from": accounts[1]},
            )
        else:
            txn = environment.notional.batchBalanceAction(
                accounts[1],
                [
                    get_balance_action(2, "DepositAssetAndMintNToken", depositActionAmount=5000e8),
                    get_balance_action(3, "DepositAssetAndMintNToken", depositActionAmount=5000e8),
                ],
                {"from": accounts[1]},
            )

        e['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert environment.approxInternal("DAI", balances[1], 100e8)

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert environment.approxInternal("USDC", balances[1], 100e8)

    check_system_invariants(environment, accounts)


def test_redeem_ntoken(environment, accounts):
    environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositAssetAndMintNToken", depositActionAmount=5000e8),
            get_balance_action(3, "DepositAssetAndMintNToken", depositActionAmount=5000e8),
        ],
        {"from": accounts[1]},
    )

    daiNTokenBalance = environment.notional.getAccountBalance(2, accounts[1])[1]
    usdcNTokenBalance = environment.notional.getAccountBalance(3, accounts[1])[1]

    with EventChecker(environment, "Redeem nToken") as e:
        txn = environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(2, "RedeemNToken", depositActionAmount=daiNTokenBalance),
                get_balance_action(3, "RedeemNToken", depositActionAmount=usdcNTokenBalance),
            ],
            {"from": accounts[1]},
        )

        e['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert environment.approxExternal("DAI", balances[0], 100e18)
    assert balances[1] == 0

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert environment.approxExternal("USDC", balances[0], 100e6)
    assert balances[1] == 0

    check_system_invariants(environment, accounts)

def test_redeem_ntoken_and_withdraw_underlying(environment, accounts):
    environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositUnderlyingAndMintNToken", depositActionAmount=100e18),
            get_balance_action(3, "DepositUnderlyingAndMintNToken", depositActionAmount=100e6),
        ],
        {"from": accounts[1]},
    )

    daiBalanceBefore = environment.token["DAI"].balanceOf(accounts[1])
    usdcBalanceBefore = environment.token["USDC"].balanceOf(accounts[1])

    daiNTokenBalance = environment.notional.getAccountBalance(2, accounts[1])[1]
    usdcNTokenBalance = environment.notional.getAccountBalance(3, accounts[1])[1]

    with EventChecker(environment, "Redeem nToken") as e:
        txn = environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(
                    2,
                    "RedeemNToken",
                    depositActionAmount=daiNTokenBalance * 0.1,
                    withdrawEntireCashBalance=True,
                    redeemToUnderlying=True,
                ),
                get_balance_action(
                    3,
                    "RedeemNToken",
                    depositActionAmount=usdcNTokenBalance * 0.1,
                    withdrawEntireCashBalance=True,
                    redeemToUnderlying=True,
                ),
            ],
            {"from": accounts[1]},
        )
        e['txn'] = txn

    daiBalanceAfter = environment.token["DAI"].balanceOf(accounts[1])
    usdcBalanceAfter = environment.token["USDC"].balanceOf(accounts[1])

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert pytest.approx(balances[1], abs=10) == daiNTokenBalance * 0.9
    assert pytest.approx(daiBalanceAfter - daiBalanceBefore, abs=1e10) == 10e18

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert pytest.approx(balances[1], abs=10) == usdcNTokenBalance * 0.9
    assert pytest.approx(usdcBalanceAfter - usdcBalanceBefore, abs=10) == 10e6

    check_system_invariants(environment, accounts)


def test_convert_cash_to_ntoken(environment, accounts):
    environment.notional.batchBalanceAction(
        accounts[1],
        [get_balance_action(2, "DepositUnderlying", depositActionAmount=100_000e18)],
        {"from": accounts[1]},
    )
    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert environment.approxExternal("DAI", balances[0], 100_000e18)
    assert balances[1] == 0
    assert balances[2] == 0

    with brownie.reverts("No Prime Borrow"):
        environment.notional.batchBalanceAction(
            accounts[1],
            [get_balance_action(2, "ConvertCashToNToken", depositActionAmount=balances[0] * 10)],
            {"from": accounts[1]},
        )

    with EventChecker(environment, "Mint nToken") as e:
        txn = environment.notional.batchBalanceAction(
            accounts[1],
            [get_balance_action(2, "ConvertCashToNToken", depositActionAmount=balances[0])],
            {"from": accounts[1]},
        )
        e['txn'] = txn

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert environment.approxInternal("DAI", balances[1], 100_000e8)

    check_system_invariants(environment, accounts)


def test_borrow_prime_to_mint_ntoken(environment, accounts):
    # Account is borrowing prime cash to mint nTokens and depositing USDC as the margin
    with brownie.reverts("No Prime Borrow"):
        environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(2, "ConvertCashToNToken", depositActionAmount=100_000e8),
                get_balance_action(3, "DepositUnderlying", depositActionAmount=30_000e6),
            ],
            {"from": accounts[1]},
        )

    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    with EventChecker(environment, "Mint nToken") as e:
        txn = environment.notional.batchBalanceAction(
            accounts[1],
            [
                get_balance_action(2, "ConvertCashToNToken", depositActionAmount=100_000e8),
                get_balance_action(3, "DepositUnderlying", depositActionAmount=30_000e6),
            ],
            {"from": accounts[1]},
        )
        e['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    assert context["hasDebt"] == HAS_CASH_DEBT

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert pytest.approx(balances[0], abs=1) == -100_000e8
    assert balances[1] == 100_000e8

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert environment.approxExternal("USDC", balances[0], 30_000e6)
    assert balances[1] == 0

    check_system_invariants(environment, accounts)
