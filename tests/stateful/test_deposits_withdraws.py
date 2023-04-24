import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import (
    active_currencies_to_list,
    get_balance_action,
    get_balance_trade_action,
    initialize_environment,
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


def test_cannot_enable_bitmap_with_zero(environment, accounts):
    with brownie.reverts():
        environment.notional.enableBitmapCurrency(0, {"from": accounts[0]})


def test_cannot_deposit_invalid_currency_id(environment, accounts):
    currencyId = 5

    with brownie.reverts():
        environment.notional.depositUnderlyingToken(
            accounts[0], currencyId, 100e6, {"from": accounts[0]}
        )

    with brownie.reverts():
        environment.notional.depositAssetToken(
            accounts[0], currencyId, 100e8, {"from": accounts[0]}
        )


def test_deposit_underlying_token_from_self(environment, accounts):
    currencyId = 2
    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.token["DAI"].transfer(accounts[1], 100e18, {"from": accounts[0]})
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.depositUnderlyingToken(
            accounts[1], currencyId, 100e18, {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(currencyId, False, True)]

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert environment.approxInternal("DAI", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_eth_underlying(environment, accounts):
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.depositUnderlyingToken(
            accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(1, False, True)]

    balances = environment.notional.getAccountBalance(1, accounts[1])
    assert environment.approxInternal("ETH", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_underlying_token_from_other(environment, accounts):
    with brownie.reverts(dev_revert_msg="dev: unauthorized"):
        environment.notional.depositUnderlyingToken(
            accounts[1], 2, 100e18, {"from": accounts[0]}
        )


def test_deposit_asset_token_from_self(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 5000e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.depositAssetToken(
            accounts[1], currencyId, 5000e8, {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(currencyId, False, True)]

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert environment.approxInternal("DAI", balances[0], 100e8)
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_withdraw_asset_token_insufficient_balance(environment, accounts):
    with brownie.reverts():
        environment.notional.withdraw(2, 100e8, False, {"from": accounts[1]})

    with brownie.reverts():
        environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})


def test_withdraw_token_to_borrow(environment, accounts):
    with brownie.reverts("No Prime Borrow"):
        environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})

    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})

    with brownie.reverts("Insufficient free collateral"):
        environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})

    # Deposit some collateral
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )

    # Now can borrow
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})
        c['txn'] = txn

    environment.notional.enablePrimeBorrow(False, {"from": accounts[1]})

    # No longer allowed to borrow further
    with brownie.reverts("No Prime Borrow"):
        environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})

    check_system_invariants(environment, accounts)


def test_cannot_max_withdraw_with_negative_balance(environment, accounts):
    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})

    # Deposit some collateral
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )

    # Now can borrow
    environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})

    # Attempt to max withdraw
    with brownie.reverts(""):
        environment.notional.withdraw(2, 2 ** 88 - 1, True, {"from": accounts[1]})

    check_system_invariants(environment, accounts)


def test_withdraw_and_redeem_token_pass_fc(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 100e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.depositAssetToken(accounts[1], currencyId, 5000e8, {"from": accounts[1]})
    cTokenBalanceBefore = environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]})

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1], {"from": accounts[0]})
    cashBalance = environment.notional.getAccountBalance(currencyId, accounts[1])[0]

    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.withdraw(currencyId, cashBalance, True, {"from": accounts[1]})
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert environment.cToken["DAI"].balanceOf(accounts[1]) == cTokenBalanceBefore
    assert environment.approxExternal(
        "DAI", cashBalance, environment.token["DAI"].balanceOf(accounts[1]) - balanceBefore
    )

    check_system_invariants(environment, accounts)


@given(redeemToETH=strategy("bool"))
def test_withdraw_and_redeem_eth(environment, accounts, redeemToETH):
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )

    if redeemToETH:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = environment.WETH.balanceOf(accounts[1])

    cashBalance = environment.notional.getAccountBalance(1, accounts[1])[0]
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.withdraw(1, cashBalance, redeemToETH, {"from": accounts[1]})
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(1, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert environment.cToken["ETH"].balanceOf(accounts[1]) == 0

    if redeemToETH:
        balanceAfter = accounts[1].balance()
    else:
        balanceAfter = environment.WETH.balanceOf(accounts[1])

    assert environment.approxExternal("ETH", cashBalance, balanceAfter - balanceBefore)

    check_system_invariants(environment, accounts)


def test_withdraw_full_balance(environment, accounts):
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )

    balances = environment.notional.getAccountBalance(1, accounts[1])
    balanceBefore = accounts[1].balance()
    with EventChecker(environment, "Account Action", account=accounts[1]) as c:
        txn = environment.notional.withdraw(1, 2 ** 88 - 1, True, {"from": accounts[1]})
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(1, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0

    balanceAfter = accounts[1].balance()
    assert balanceAfter - balanceBefore == 100e18

    check_system_invariants(environment, accounts)


def test_eth_failures(environment, accounts):
    with brownie.reverts("ETH Balance"):
        # Should revert, no msg.value
        environment.notional.depositUnderlyingToken(accounts[1], 1, 1e18, {"from": accounts[1]})

    with brownie.reverts("ETH Balance"):
        # Should revert, no msg.value
        environment.notional.batchBalanceAction(
            accounts[0], [get_balance_action(1, "DepositUnderlying", depositActionAmount=1e18)]
        )

    with brownie.reverts("ETH Balance"):
        # Should revert, no msg.value
        environment.notional.batchBalanceAndTradeAction(
            accounts[0],
            [get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=1e18)],
        )


def test_withdraw_asset_token_fail_fc(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": fCashAmount,
                "maxSlippage": 0,
            }
        ],
        depositActionAmount=3e18,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction], {"from": accounts[1]}
    )
    (cashBalance, _, _) = environment.notional.getAccountBalance(2, accounts[1])

    # Will fail FC check
    with brownie.reverts("Insufficient free collateral"):
        environment.notional.withdraw(2, cashBalance, True, {"from": accounts[1]})
        environment.notional.withdraw(2, cashBalance, False, {"from": accounts[1]})

    check_system_invariants(environment, accounts)


def test_fail_on_deposits_exceeding_supply_cap(environment, accounts):
    currencyId = 2
    factors = environment.notional.getPrimeFactorsStored(currencyId)
    environment.notional.setMaxUnderlyingSupply(currencyId, factors['lastTotalUnderlyingValue'] + 125e8)
    (_, _, maxUnderlyingSupply, totalUnderlyingSupply) = environment.notional.getPrimeFactors(currencyId, chain.time() + 1)
    # This is approximately equal
    assert pytest.approx(maxUnderlyingSupply - totalUnderlyingSupply, rel=1e8) == 125e8

    # Should succeed
    environment.notional.depositUnderlyingToken(
        accounts[1], currencyId, 50e18, {"from": accounts[1]}
    )
    (_, _, maxUnderlyingSupply, totalUnderlyingSupply) = environment.notional.getPrimeFactors(currencyId, chain.time() + 1)
    assert pytest.approx(maxUnderlyingSupply - totalUnderlyingSupply, rel=1e8) == 75e8

    # Should fail
    with brownie.reverts("Over Supply Cap"):
        environment.notional.depositUnderlyingToken(
            accounts[1], currencyId, 200e18, {"from": accounts[1]}
        )

    with brownie.reverts("Over Supply Cap"):
        environment.notional.depositAssetToken(
            accounts[1], currencyId, 5000e8, {"from": accounts[1]}
        )

    # increase amount
    factors = environment.notional.getPrimeFactorsStored(currencyId)
    environment.notional.setMaxUnderlyingSupply(currencyId, factors['lastTotalUnderlyingValue'] + 125e8)
    (_, _, maxUnderlyingSupply, totalUnderlyingSupply) = environment.notional.getPrimeFactors(currencyId, chain.time() + 1)
    assert pytest.approx(maxUnderlyingSupply - totalUnderlyingSupply, rel=1e8) == 200e8

    # Should succeed
    environment.notional.depositUnderlyingToken(
        accounts[1], currencyId, 50e18, {"from": accounts[1]}
    )
    environment.notional.depositAssetToken(
        accounts[1], currencyId, 2500e8, {"from": accounts[1]}
    )

    # decrease amount
    environment.notional.setMaxUnderlyingSupply(currencyId, 1e8)
    (_, _, maxUnderlyingSupply, totalUnderlyingSupply) = environment.notional.getPrimeFactors(currencyId, chain.time() + 1)
    assert maxUnderlyingSupply < totalUnderlyingSupply

    # Should succeed
    environment.notional.withdraw(currencyId, 150e8, True, {"from": accounts[1]})

    check_system_invariants(environment, accounts)