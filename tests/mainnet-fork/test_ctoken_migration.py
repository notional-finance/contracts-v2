import pytest
from brownie import accounts, interface, Wei
from brownie.network.state import Chain
from scripts.CTokenMigrationEnvironment import cTokenMigrationEnvironment
from tests.helpers import get_balance_action, get_balance_trade_action

chain = Chain()

@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

@pytest.fixture(scope="module", autouse=True)
def env(accounts):
    return cTokenMigrationEnvironment(accounts[0])

def snapshot_invariants(env, currencyId):
    snapshot = {}
    snapshot["assetRate"] = env.notional.getCurrencyAndRates(currencyId)["assetRate"]["rate"]
    return snapshot

def check_invariants(env, snapshot, currencyId):
    # Final asset rate shouldn't move once set
    assert snapshot["assetRate"] == env.notional.getCurrencyAndRates(currencyId)["assetRate"]["rate"]

def deposit_underlying(env, account, currencyId, amount):
    value = 0
    if currencyId == 1:
        value = amount
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        token.approve(env.notional, 2**256-1, {"from": account})
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalanceBefore = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    chain.undo()
    env.deployNCTokens()
    env.migrate(currencyId)
    snapshot = snapshot_invariants(env, currencyId)
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalanceAfter = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    assert pytest.approx(cashBalanceBefore, rel=1e-7) == cashBalanceAfter
    check_invariants(env, snapshot, currencyId)

def deposit_asset(env, account, currencyId, amount):
    if currencyId == 1:
        cToken = interface.CEtherInterface(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])
        cToken.mint({"from": account, "value": amount})
    else:
        cToken = interface.CErc20Interface(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])
        underlying = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        underlying.approve(cToken, 2**256-1, {"from": account})
        cToken.mint(amount, {"from": account})

    assetToken = interface.IERC20(cToken.address)
    assetToken.approve(env.notional, 2**256-1, {"from": account})
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositAsset", depositActionAmount=assetToken.balanceOf(account))],
        {"from": account}
    )
    cashBalanceBefore = env.notional.getAccountBalance(currencyId, account)["cashBalance"]

    chain.undo()

    env.deployNCTokens()
    env.migrate(currencyId)

    ncToken = interface.ncTokenInterface(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])
    if currencyId == 1:
        ncToken.mint({"from": account, "value": amount})
    else:
        underlying = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        underlying.approve(ncToken, 2**256-1, {"from": account})
        ncToken.mint(amount, {"from": account})

    assetToken = interface.IERC20(ncToken.address)
    assetToken.approve(env.notional, 2**256-1, {"from": account})
    snapshot = snapshot_invariants(env, currencyId)
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositAsset", depositActionAmount=assetToken.balanceOf(account))],
        {"from": account}
    )
    cashBalanceAfter = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    assert pytest.approx(cashBalanceBefore, rel=1e-7) == cashBalanceAfter
    check_invariants(env, snapshot, currencyId)

def redeem_underlying(env, account, currencyId, amount):
    value = 0
    if currencyId == 1:
        value = amount
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        token.approve(env.notional, 2**256-1, {"from": account})
    env.deployNCTokens()
    env.migrate(currencyId)
    snapshot = snapshot_invariants(env, currencyId)
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalance = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "None", withdrawAmountInternalPrecision=Wei(cashBalance / 2))],
        {"from": account}
    )
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "None", withdrawEntireCashBalance=True)],
        {"from": account}
    )
    assert env.notional.getAccountBalance(currencyId, account)["cashBalance"] == 0
    check_invariants(env, snapshot, currencyId)

def redeem_asset(env, currencyid, amount):
    pass

def test_deposit_underlying_eth(env):
    deposit_underlying(env, accounts[0], 1, 10e18)

def test_deposit_underlying_dai(env):
    deposit_underlying(env, env.whales["DAI"], 2, 10000e18)

def test_deposit_underlying_usdc(env):
    deposit_underlying(env, env.whales["USDC"], 3, 10000e6)

def test_deposit_underlying_wbtc(env):
    deposit_underlying(env, env.whales["WBTC"], 4, 1e8)

def test_deposit_asset_eth(env):
    deposit_asset(env, accounts[0], 1, 10e18)

def test_deposit_asset_dai(env):
    deposit_asset(env, env.whales["DAI"], 2, 10000e18)

def test_deposit_asset_usdc(env):
    deposit_asset(env, env.whales["USDC"], 3, 10000e6)

def test_deposit_asset_wbtc(env):
    deposit_asset(env, env.whales["WBTC"], 4, 1e8)

def test_redeem_underlying_eth(env):
    redeem_underlying(env, accounts[0], 1, 10e18)

def test_redeem_underlying_dai(env):
    redeem_underlying(env, env.whales["DAI"], 2, 10000e18)

def test_redeem_underlying_usdc(env):
    redeem_underlying(env, env.whales["USDC"], 3, 10000e6)

def test_redeem_underlying_wbtc(env):
    redeem_underlying(env, env.whales["WBTC"], 4, 1e8)