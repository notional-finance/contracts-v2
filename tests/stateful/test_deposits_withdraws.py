import brownie
import pytest
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import active_currencies_to_list, get_tref
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = TestEnvironment(accounts[0])
    env.enableCurrency("DAI", CurrencyDefaults)

    cToken = env.cToken["DAI"]
    token = env.token["DAI"]
    token.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    token.approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e18, {"from": accounts[0]})
    cToken.approve(env.proxy.address, 2 ** 255, {"from": accounts[0]})

    # Set the blocktime to the begnning of the next tRef otherwise the rates will blow up
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    # TODO: maybe do multiple currencies?
    currencyId = 2
    env.notional.updatePerpetualDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])

    env.notional.updateInitializationParameters(currencyId, [1.01e9, 1.021e9], [0.5e9, 0.5e9])

    env.notional.perpetualTokenMint(currencyId, 100000e8, False, {"from": accounts[0]})
    env.notional.initializeMarkets(currencyId, True)

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_cannot_deposit_invalid_currency_id(environment, accounts):
    currencyId = 3

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
    cTokenSupplyBefore = environment.cToken["DAI"].totalSupply()
    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.token["DAI"].transfer(accounts[1], 100e18, {"from": accounts[0]})
    txn = environment.notional.depositUnderlyingToken(
        accounts[1], currencyId, 100e18, {"from": accounts[1]}
    )
    cTokenSupplyAfter = environment.cToken["DAI"].totalSupply()

    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["amount"] == cTokenSupplyAfter - cTokenSupplyBefore

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(currencyId, False, True)]

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == cTokenSupplyAfter - cTokenSupplyBefore
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_underlying_token_from_other(environment, accounts):
    currencyId = 2
    cTokenSupplyBefore = environment.cToken["DAI"].totalSupply()
    txn = environment.notional.depositUnderlyingToken(
        accounts[1], currencyId, 100e18, {"from": accounts[0]}
    )
    cTokenSupplyAfter = environment.cToken["DAI"].totalSupply()

    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["amount"] == cTokenSupplyAfter - cTokenSupplyBefore

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(currencyId, False, True)]

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == cTokenSupplyAfter - cTokenSupplyBefore
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_asset_token_from_self(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 100e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    txn = environment.notional.depositAssetToken(
        accounts[1], currencyId, 100e8, {"from": accounts[1]}
    )
    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["amount"] == 100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(currencyId, False, True)]

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == 100e8
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_withdraw_asset_token_insufficient_balance(environment, accounts):
    with brownie.reverts():
        environment.notional.withdraw(accounts[1], 2, 100e8, False, {"from": accounts[1]})

    with brownie.reverts():
        environment.notional.withdraw(accounts[1], 2, 100e8, True, {"from": accounts[1]})


def test_withdraw_asset_token_pass_fc(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 100e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.depositAssetToken(accounts[1], currencyId, 100e8, {"from": accounts[1]})

    txn = environment.notional.withdraw(
        accounts[1], currencyId, 100e8, False, {"from": accounts[1]}
    )
    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["amount"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]}) == 100e8

    check_system_invariants(environment, accounts)


def test_withdraw_and_redeem_token_pass_fc(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 100e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.depositAssetToken(accounts[1], currencyId, 100e8, {"from": accounts[1]})

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1], {"from": accounts[0]})
    txn = environment.notional.withdraw(accounts[1], currencyId, 100e8, True, {"from": accounts[1]})
    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["amount"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]}) == 0
    assert environment.token["DAI"].balanceOf(accounts[1], {"from": accounts[0]}) > balanceBefore

    check_system_invariants(environment, accounts)


def test_withdraw_asset_token_fail_fc(environment, accounts):
    pass
