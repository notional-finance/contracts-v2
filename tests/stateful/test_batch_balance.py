import brownie
import pytest
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import active_currencies_to_list, get_balance_action, get_tref
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = TestEnvironment(accounts[0])
    env.enableCurrency("DAI", CurrencyDefaults)
    env.enableCurrency("USDC", CurrencyDefaults)

    cToken = env.cToken["DAI"]
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["DAI"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e18, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["DAI"].transfer(accounts[1], 1000e18, {"from": accounts[0]})
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 1000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    cToken = env.cToken["USDC"]
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["USDC"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(10000000e6, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    env.token["USDC"].transfer(accounts[1], 1000e6, {"from": accounts[0]})
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    cToken.transfer(accounts[1], 1000e8, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})

    # Set the blocktime to the begnning of the next tRef otherwise the rates will blow up
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    currencyId = 2
    env.notional.updatePerpetualDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])
    env.notional.updateInitializationParameters(currencyId, [1.01e9, 1.021e9], [0.5e9, 0.5e9])
    env.notional.perpetualTokenMint(currencyId, 100000e8, False, {"from": accounts[0]})
    env.notional.initializeMarkets(currencyId, True)

    currencyId = 3
    env.notional.updatePerpetualDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])
    env.notional.updateInitializationParameters(currencyId, [1.01e9, 1.021e9], [0.5e9, 0.5e9])
    env.notional.perpetualTokenMint(currencyId, 100000e8, False, {"from": accounts[0]})
    env.notional.initializeMarkets(currencyId, True)

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_fails_on_unordered_currencies(environment, accounts):
    with brownie.reverts("Unsorted actions"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(3, "DepositAsset", depositActionAmount=int(100e8)),
                get_balance_action(2, "DepositAsset", depositActionAmount=int(100e8)),
            ],
        )

    with brownie.reverts("Unsorted actions"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(2, "DepositAsset", depositActionAmount=100e8),
                get_balance_action(2, "DepositAsset", depositActionAmount=100e8),
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


def test_deposit_asset_batch(environment, accounts):
    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositAsset", depositActionAmount=100e8),
            get_balance_action(3, "DepositAsset", depositActionAmount=100e8),
        ],
        {"from": accounts[1]},
    )

    assert txn.events["CashBalanceChange"][0]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"][0]["currencyId"] == 2
    assert txn.events["CashBalanceChange"][0]["amount"] == 100e8

    assert txn.events["CashBalanceChange"][1]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"][1]["currencyId"] == 3
    assert txn.events["CashBalanceChange"][1]["amount"] == 100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 100e8
    assert balances[1] == 0
    assert balances[2] == 0

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 100e8
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_underlying_batch(environment, accounts):
    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositUnderlying", depositActionAmount=100e18),
            get_balance_action(3, "DepositUnderlying", depositActionAmount=100e6),
        ],
        {"from": accounts[1]},
    )

    assert txn.events["CashBalanceChange"][0]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"][0]["currencyId"] == 2
    assert txn.events["CashBalanceChange"][0]["amount"] == 5000e8

    assert txn.events["CashBalanceChange"][1]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"][1]["currencyId"] == 3
    assert txn.events["CashBalanceChange"][1]["amount"] == 5000e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 5000e8
    assert balances[1] == 0
    assert balances[2] == 0

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 5000e8
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_asset_and_mint_perpetual(environment, accounts):
    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositAssetAndMintPerpetual", depositActionAmount=100e8),
            get_balance_action(3, "DepositAssetAndMintPerpetual", depositActionAmount=100e8),
        ],
        {"from": accounts[1]},
    )

    assert txn.events["PerpetualTokenSupplyChange"][0]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][0]["currencyId"] == 2
    assert txn.events["PerpetualTokenSupplyChange"][0]["amount"] == 100e8

    assert txn.events["PerpetualTokenSupplyChange"][1]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][1]["currencyId"] == 3
    assert txn.events["PerpetualTokenSupplyChange"][1]["amount"] == 100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 100e8
    assert balances[2] == txn.timestamp

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 100e8
    assert balances[2] == txn.timestamp

    check_system_invariants(environment, accounts)


def test_deposit_underlying_and_mint_perpetual(environment, accounts):
    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositUnderlyingAndMintPerpetual", depositActionAmount=100e18),
            get_balance_action(3, "DepositUnderlyingAndMintPerpetual", depositActionAmount=100e6),
        ],
        {"from": accounts[1]},
    )

    assert txn.events["PerpetualTokenSupplyChange"][0]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][0]["currencyId"] == 2
    assert txn.events["PerpetualTokenSupplyChange"][0]["amount"] == 5000e8

    assert txn.events["PerpetualTokenSupplyChange"][1]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][1]["currencyId"] == 3
    assert txn.events["PerpetualTokenSupplyChange"][1]["amount"] == 5000e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 5000e8
    assert balances[2] == txn.timestamp

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 5000e8
    assert balances[2] == txn.timestamp

    check_system_invariants(environment, accounts)


def test_redeem_perpetual(environment, accounts):
    environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositAssetAndMintPerpetual", depositActionAmount=100e8),
            get_balance_action(3, "DepositAssetAndMintPerpetual", depositActionAmount=100e8),
        ],
        {"from": accounts[1]},
    )

    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "RedeemPerpetual", depositActionAmount=100e8),
            get_balance_action(3, "RedeemPerpetual", depositActionAmount=100e8),
        ],
        {"from": accounts[1]},
    )

    assert txn.events["PerpetualTokenSupplyChange"][0]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][0]["currencyId"] == 2
    assert txn.events["PerpetualTokenSupplyChange"][0]["amount"] == -100e8

    assert txn.events["PerpetualTokenSupplyChange"][1]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][1]["currencyId"] == 3
    assert txn.events["PerpetualTokenSupplyChange"][1]["amount"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 100e8
    assert balances[1] == 0
    assert balances[2] == txn.timestamp

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 100e8
    assert balances[1] == 0
    assert balances[2] == txn.timestamp
    # TODO: test incentives

    check_system_invariants(environment, accounts)


def test_redeem_perpetual_and_withdraw_asset(environment, accounts):
    environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositAssetAndMintPerpetual", depositActionAmount=100e8),
            get_balance_action(3, "DepositAssetAndMintPerpetual", depositActionAmount=100e8),
        ],
        {"from": accounts[1]},
    )

    daiBalanceBefore = environment.cToken["DAI"].balanceOf(accounts[1])
    usdcBalanceBefore = environment.cToken["USDC"].balanceOf(accounts[1])

    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(
                2, "RedeemPerpetual", depositActionAmount=100e8, withdrawEntireCashBalance=True
            ),
            get_balance_action(
                3, "RedeemPerpetual", depositActionAmount=100e8, withdrawEntireCashBalance=True
            ),
        ],
        {"from": accounts[1]},
    )

    daiBalanceAfter = environment.cToken["DAI"].balanceOf(accounts[1])
    usdcBalanceAfter = environment.cToken["USDC"].balanceOf(accounts[1])

    assert txn.events["PerpetualTokenSupplyChange"][0]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][0]["currencyId"] == 2
    assert txn.events["PerpetualTokenSupplyChange"][0]["amount"] == -100e8

    assert txn.events["PerpetualTokenSupplyChange"][1]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][1]["currencyId"] == 3
    assert txn.events["PerpetualTokenSupplyChange"][1]["amount"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == txn.timestamp
    assert daiBalanceAfter - daiBalanceBefore == 100e8

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == txn.timestamp
    assert usdcBalanceAfter - usdcBalanceBefore == 100e8
    # TODO: test incentives

    check_system_invariants(environment, accounts)


def test_redeem_perpetual_and_withdraw_underlying(environment, accounts):
    environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(2, "DepositUnderlyingAndMintPerpetual", depositActionAmount=100e18),
            get_balance_action(3, "DepositUnderlyingAndMintPerpetual", depositActionAmount=100e6),
        ],
        {"from": accounts[1]},
    )

    daiBalanceBefore = environment.token["DAI"].balanceOf(accounts[1])
    usdcBalanceBefore = environment.token["USDC"].balanceOf(accounts[1])

    txn = environment.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(
                2,
                "RedeemPerpetual",
                depositActionAmount=100e8,
                withdrawEntireCashBalance=True,
                redeemToUnderlying=True,
            ),
            get_balance_action(
                3,
                "RedeemPerpetual",
                depositActionAmount=100e8,
                withdrawEntireCashBalance=True,
                redeemToUnderlying=True,
            ),
        ],
        {"from": accounts[1]},
    )

    daiBalanceAfter = environment.token["DAI"].balanceOf(accounts[1])
    usdcBalanceAfter = environment.token["USDC"].balanceOf(accounts[1])

    assert txn.events["PerpetualTokenSupplyChange"][0]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][0]["currencyId"] == 2
    assert txn.events["PerpetualTokenSupplyChange"][0]["amount"] == -100e8

    assert txn.events["PerpetualTokenSupplyChange"][1]["account"] == accounts[1]
    assert txn.events["PerpetualTokenSupplyChange"][1]["currencyId"] == 3
    assert txn.events["PerpetualTokenSupplyChange"][1]["amount"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, False, True), (3, False, True)]

    balances = environment.notional.getAccountBalance(2, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 4900e8
    assert balances[2] == txn.timestamp
    assert daiBalanceAfter - daiBalanceBefore == 2e18

    balances = environment.notional.getAccountBalance(3, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 4900e8
    assert balances[2] == txn.timestamp
    assert usdcBalanceAfter - usdcBalanceBefore == 2e6

    check_system_invariants(environment, accounts)
