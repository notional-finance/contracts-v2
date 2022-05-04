import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TokenType
from tests.helpers import (
    active_currencies_to_list,
    get_balance_action,
    get_balance_trade_action,
    initialize_environment,
)
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
    cTokenSupplyBefore = environment.cToken["DAI"].totalSupply()
    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.token["DAI"].transfer(accounts[1], 100e18, {"from": accounts[0]})
    txn = environment.notional.depositUnderlyingToken(
        accounts[1], currencyId, 100e18, {"from": accounts[1]}
    )
    cTokenSupplyAfter = environment.cToken["DAI"].totalSupply()

    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert (
        txn.events["CashBalanceChange"]["netCashChange"] == cTokenSupplyAfter - cTokenSupplyBefore
    )

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(currencyId, False, True)]

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == cTokenSupplyAfter - cTokenSupplyBefore
    assert balances[1] == 0
    assert balances[2] == 0

    check_system_invariants(environment, accounts)


def test_deposit_eth_underlying(environment, accounts):
    cTokenSupplyBefore = environment.cToken["ETH"].totalSupply()
    txn = environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )
    assert environment.notional.balance() == 0
    cTokenSupplyAfter = environment.cToken["ETH"].totalSupply()

    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == 1
    assert (
        txn.events["CashBalanceChange"]["netCashChange"] == cTokenSupplyAfter - cTokenSupplyBefore
    )

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(1, False, True)]

    balances = environment.notional.getAccountBalance(1, accounts[1])
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
    assert (
        txn.events["CashBalanceChange"]["netCashChange"] == cTokenSupplyAfter - cTokenSupplyBefore
    )

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
    assert txn.events["CashBalanceChange"]["netCashChange"] == 100e8

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
        environment.notional.withdraw(2, 100e8, False, {"from": accounts[1]})

    with brownie.reverts():
        environment.notional.withdraw(2, 100e8, True, {"from": accounts[1]})


def test_withdraw_asset_token_pass_fc(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 100e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.depositAssetToken(accounts[1], currencyId, 100e8, {"from": accounts[1]})
    balanceBefore = environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]})

    txn = environment.notional.withdraw(currencyId, 100e8, False, {"from": accounts[1]})
    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["netCashChange"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert (
        environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]})
        == balanceBefore + 100e8
    )

    check_system_invariants(environment, accounts)


def test_withdraw_and_redeem_token_pass_fc(environment, accounts):
    currencyId = 2
    environment.cToken["DAI"].transfer(accounts[1], 100e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
    environment.notional.depositAssetToken(accounts[1], currencyId, 100e8, {"from": accounts[1]})
    cTokenBalanceBefore = environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]})

    balanceBefore = environment.token["DAI"].balanceOf(accounts[1], {"from": accounts[0]})
    txn = environment.notional.withdraw(currencyId, 100e8, True, {"from": accounts[1]})
    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == currencyId
    assert txn.events["CashBalanceChange"]["netCashChange"] == -100e8

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert (
        environment.cToken["DAI"].balanceOf(accounts[1], {"from": accounts[0]})
        == cTokenBalanceBefore
    )
    assert environment.token["DAI"].balanceOf(accounts[1], {"from": accounts[0]}) > balanceBefore

    check_system_invariants(environment, accounts)


def test_withdraw_and_redeem_eth(environment, accounts):
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )

    balanceBefore = accounts[1].balance()
    cTokenSupplyBefore = environment.cToken["ETH"].totalSupply()
    txn = environment.notional.withdraw(1, 5000e8, True, {"from": accounts[1]})
    assert environment.notional.balance() == 0
    cTokenSupplyAfter = environment.cToken["ETH"].totalSupply()

    assert txn.events["CashBalanceChange"]["account"] == accounts[1]
    assert txn.events["CashBalanceChange"]["currencyId"] == 1
    assert (
        txn.events["CashBalanceChange"]["netCashChange"] == cTokenSupplyAfter - cTokenSupplyBefore
    )

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []

    balances = environment.notional.getAccountBalance(1, accounts[1])
    assert balances[0] == 0
    assert balances[1] == 0
    assert balances[2] == 0
    assert environment.cToken["ETH"].balanceOf(accounts[1]) == 0
    assert accounts[1].balance() > balanceBefore

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


def test_fail_on_deposit_over_max_collateral(environment, accounts):
    zeroAddress = HexString(0, "bytes20")
    txn = environment.notional.listCurrency(
        (environment.token["NOMINT"].address, False, TokenType["NonMintable"], 18, 100e8),
        (zeroAddress, False, 0, 0, 0),
        environment.ethOracle["NOMINT"].address,
        False,
        130,
        70,
        105,
    )

    environment.token["NOMINT"].approve(
        environment.notional.address, 2 ** 255, {"from": accounts[1]}
    )
    environment.token["NOMINT"].transfer(accounts[1], 1000e18, {"from": accounts[0]})
    currencyId = txn.events["ListCurrency"]["newCurrencyId"]

    # Should succeed
    environment.notional.depositAssetToken(accounts[1], currencyId, 50e18, {"from": accounts[1]})

    # Should fail
    with brownie.reverts():
        environment.notional.depositAssetToken(
            accounts[1], currencyId, 200e18, {"from": accounts[1]}
        )

    # increase amount
    environment.notional.updateMaxCollateralBalance(currencyId, 200e8)

    # Should succeed
    environment.notional.depositAssetToken(accounts[1], currencyId, 100e18, {"from": accounts[1]})

    # decrease amount
    environment.notional.updateMaxCollateralBalance(currencyId, 1e8)

    # Should succeed
    environment.notional.withdraw(currencyId, 150e8, False, {"from": accounts[1]})

    check_system_invariants(environment, accounts)


def test_cannot_set_max_collateral_on_traded_cash(environment, accounts):
    with brownie.reverts():
        environment.notional.updateMaxCollateralBalance(2, 200e8)


def test_cannot_enable_cash_group_on_capped_token(environment, accounts):
    zeroAddress = HexString(0, "bytes20")
    txn = environment.notional.listCurrency(
        (environment.token["NOMINT"].address, False, TokenType["NonMintable"], 18, 100e8),
        (zeroAddress, False, 0, 0, 0),
        environment.ethOracle["NOMINT"].address,
        False,
        130,
        70,
        105,
    )

    currencyId = txn.events["ListCurrency"]["newCurrencyId"]
    with brownie.reverts():
        config = CurrencyDefaults
        environment.notional.enableCashGroup(
            currencyId,
            zeroAddress,
            (
                config["maxMarketIndex"],
                config["rateOracleTimeWindow"],
                config["totalFee"],
                config["reserveFeeShare"],
                config["debtBuffer"],
                config["fCashHaircut"],
                config["settlementPenalty"],
                config["liquidationfCashDiscount"],
                config["liquidationDebtBuffer"],
                config["tokenHaircut"][0 : config["maxMarketIndex"]],
                config["rateScalar"][0 : config["maxMarketIndex"]],
            ),
            "NOMINT",
            "NOMINT",
        )
