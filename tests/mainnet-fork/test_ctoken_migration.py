import pytest
import json
import brownie
import math
from brownie import Contract, accounts, interface, Wei
from brownie.network.state import Chain
from scripts.CTokenMigrationEnvironment import cTokenMigrationEnvironment
from tests.helpers import get_balance_action

chain = Chain()

wfCashABI = json.load(open("abi/WrappedfCash.json"))
wfCashFactoryABI = json.load(open("abi/WrappedfCashFactory.json"))

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

def test_donation_does_not_affect_contract(env, accounts):
    env.deployNCTokens()
    env.migrateAll()
    assetRateBefore = env.ncTokens[1].getExchangeRateStateful({"from": accounts[0]}).return_value
    accounts[0].transfer(env.ncTokens[1], 100e18)
    assetRateAfter = env.ncTokens[1].getExchangeRateStateful({"from": accounts[0]}).return_value
    assert assetRateAfter == assetRateBefore

    assert env.ncTokens[1].balanceOf(accounts[0]) == 0
    env.ncTokens[1].mint({"value": 10e18, "from": accounts[0]})
    assert pytest.approx(
        Wei(env.ncTokens[1].balanceOf(accounts[0])) * Wei(env.ncTokens[1].getExchangeRateView()) / Wei(1e18), rel=1e10
    ) == 10e18


def test_only_notional_can_initialize(env, accounts):
    env.deployNCTokens()

    with brownie.reverts():
        env.ncTokens[1].initialize(1e18, {"from": accounts[0]})

def test_wrapper_names(env):
    env.deployNCTokens()
    # Migration is required for initialization
    env.migrateAll()
    assert env.ncTokens[1].name() == 'Notional Wrapped Ether'
    assert env.ncTokens[2].name() == 'Notional Wrapped Dai Stablecoin'
    assert env.ncTokens[3].name() == 'Notional Wrapped USD Coin'
    assert env.ncTokens[4].name() == 'Notional Wrapped Wrapped BTC'

    assert env.ncTokens[1].symbol() == 'nwETH'
    assert env.ncTokens[2].symbol() == 'nwDAI'
    assert env.ncTokens[3].symbol() == 'nwUSDC'
    assert env.ncTokens[4].symbol() == 'nwWBTC'

def test_safety_check_locks_contract(env, accounts):
    env.deployNCTokens()
    # Migration is required for initialization
    env.migrateAll()

    underlying = interface.IERC20(env.notional.getCurrencyAndRates(2)["underlyingToken"][0])
    asset = interface.nwTokenInterface(env.notional.getCurrencyAndRates(2)["assetToken"][0])
    # Simulate an attack that somehow takes DAI
    underlying.transfer(accounts[0], 100e18, {"from": env.ncTokens[2]})

    # Assert that minting and redeeming is no longer possible
    underlying.approve(asset, 2 ** 256 - 1, {"from": env.whales["DAI"]})
    with brownie.reverts("Invariant Failed"):
        asset.mint(100e18, {"from": env.whales["DAI"]})

    with brownie.reverts("Invariant Failed"):
        asset.redeem(100e8, {"from": env.notional})

    with brownie.reverts("Invariant Failed"):
        asset.redeemUnderlying(100e8, {"from": env.notional})

def test_can_redeem_all_tokens(env):
    env.deployNCTokens()
    env.migrateAll()

    for i in range(1, 5):
        if i != 1:
            underlying = interface.IERC20(env.notional.getCurrencyAndRates(i)["underlyingToken"][0])
        asset = interface.IERC20(env.notional.getCurrencyAndRates(i)["assetToken"][0])
        nwAsset = interface.nwTokenInterface(env.notional.getCurrencyAndRates(i)["assetToken"][0])

        balanceOfAssetBefore = underlying.balanceOf(asset.address) if i != 1 else asset.balance()
        balanceOfNotionalBefore = underlying.balanceOf(env.notional.address) if i != 1 else env.notional.balance()

        nwAsset.redeem(asset.balanceOf(env.notional), {"from": env.notional})

        remainingAssetBalance = underlying.balanceOf(asset.address) if i != 1 else asset.balance()
        # Assert that only dust remains at a full redemption
        if i == 1 or underlying.decimals() == 18:
            assert remainingAssetBalance < 3e10
        elif underlying.decimals() == 8:
            assert remainingAssetBalance < 5
        elif underlying.decimals() == 6:
            assert remainingAssetBalance < 2

        balanceOfNotionalAfter = underlying.balanceOf(env.notional.address) if i != 1 else env.notional.balance()

        assert balanceOfAssetBefore - remainingAssetBalance + balanceOfNotionalBefore == balanceOfNotionalAfter


def deposit_underlying(env, account, currencyId, amount):
    value = 0
    if currencyId == 1:
        value = amount
        accountBalanceBefore = account.balance()
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        token.approve(env.notional, 2**256-1, {"from": account})
        accountBalanceBefore = token.balanceOf(account)

    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalanceBefore = env.notional.getAccountBalance(currencyId, account)["cashBalance"]

    if currencyId == 1:
        deposited = accountBalanceBefore - account.balance()
    else:
        deposited = accountBalanceBefore - token.balanceOf(account)

    chain.undo()
    env.deployNCTokens()
    env.migrateAll()

    snapshot = snapshot_invariants(env, currencyId)

    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalanceAfter = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    if currencyId == 1:
        assert deposited == accountBalanceBefore - account.balance()
    else:
        assert deposited == accountBalanceBefore - token.balanceOf(account)

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
    accountBalanceBefore = assetToken.balanceOf(account)

    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositAsset", depositActionAmount=assetToken.balanceOf(account))],
        {"from": account}
    )
    cashBalanceBefore = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    deposited = accountBalanceBefore - assetToken.balanceOf(account)

    chain.undo()

    env.deployNCTokens()
    env.migrateAll()

    nwToken = interface.nwTokenInterface(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])
    if currencyId == 1:
        nwToken.mint({"from": account, "value": amount})
    else:
        underlying = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        underlying.approve(nwToken, 2**256-1, {"from": account})
        nwToken.mint(amount, {"from": account})

    assetToken = interface.IERC20(nwToken.address)
    assetToken.approve(env.notional, 2**256-1, {"from": account})
    accountBalanceBefore = assetToken.balanceOf(account)
    snapshot = snapshot_invariants(env, currencyId)
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositAsset", depositActionAmount=assetToken.balanceOf(account))],
        {"from": account}
    )
    cashBalanceAfter = env.notional.getAccountBalance(currencyId, account)["cashBalance"]
    assert pytest.approx(deposited, rel=1e-7) == accountBalanceBefore - assetToken.balanceOf(account)
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
    env.migrateAll()
    snapshot = snapshot_invariants(env, currencyId)

    # Clear any residual cash balance from previous tests
    if env.notional.getAccountBalance(currencyId, account)["cashBalance"] > 0:
        env.notional.batchBalanceAction(
            account, [get_balance_action(currencyId, "None", withdrawEntireCashBalance=True, redeemToUnderlying=True)],
            {"from": account}
        )

    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalance = env.notional.getAccountBalance(currencyId, account)["cashBalance"]

    if currencyId == 1:
        accountBalanceBefore = account.balance()
    else:
        accountBalanceBefore = token.balanceOf(account)

    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "None", withdrawAmountInternalPrecision=Wei(cashBalance / 2), redeemToUnderlying=True)],
        {"from": account}
    )
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "None", withdrawEntireCashBalance=True, redeemToUnderlying=True)],
        {"from": account}
    )

    if currencyId == 1:
        assert pytest.approx(amount, rel=1e-7, abs=3) == account.balance() - accountBalanceBefore
    else:
        assert pytest.approx(amount, rel=1e-7, abs=3) == token.balanceOf(account) - accountBalanceBefore

    assert env.notional.getAccountBalance(currencyId, account)["cashBalance"] == 0
    check_invariants(env, snapshot, currencyId)

def redeem_asset(env, account, currencyId, amount):
    value = 0
    if currencyId == 1:
        value = amount
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        token.approve(env.notional, 2**256-1, {"from": account})

    env.deployNCTokens()
    env.migrateAll()
    snapshot = snapshot_invariants(env, currencyId)
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "DepositUnderlying", depositActionAmount=amount)],
        {"from": account, "value": value}
    )
    cashBalance = env.notional.getAccountBalance(currencyId, account)["cashBalance"]

    nwToken = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])
    accountBalanceBefore = nwToken.balanceOf(account)

    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "None", withdrawAmountInternalPrecision=Wei(cashBalance / 2), redeemToUnderlying=False)],
        {"from": account}
    )
    env.notional.batchBalanceAction(
        account, [get_balance_action(currencyId, "None", withdrawEntireCashBalance=True, redeemToUnderlying=False)],
        {"from": account}
    )

    assert cashBalance == nwToken.balanceOf(account) - accountBalanceBefore
    assert env.notional.getAccountBalance(currencyId, account)["cashBalance"] == 0
    check_invariants(env, snapshot, currencyId)

def wrapped_fcash_mint_via_underlying(env, account, currencyId, fCashAmount):
    markets = env.notional.getActiveMarkets(currencyId)
    wfCashFactory = Contract.from_abi("wfCash Factory", "0x5D051DeB5db151C2172dCdCCD42e6A2953E27261", wfCashFactoryABI)
    wfCashAddress = wfCashFactory.deployWrapper(currencyId, markets[0][1], {"from": accounts[1]}).return_value
    wfCash = Contract.from_abi('wfCash', wfCashAddress, wfCashABI)

    env.deployNCTokens()
    env.migrateAll()
    snapshot = snapshot_invariants(env, currencyId)

    if currencyId != 1:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])

    amount = math.floor(wfCash.previewMint(fCashAmount) * 1.000001)

    # wfETH uses WETH
    WETH = interface.WETH9("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
    if currencyId == 1:
        WETH.deposit({"from": account, "value": amount})
        token = interface.IERC20(WETH.address)

    accountBalanceBefore = token.balanceOf(account)
    token.approve(wfCash, 2**256-1, {"from": account})

    wfCash.mintViaUnderlying(amount, fCashAmount, account, 0, {"from": account})

    if currencyId == 1:
        assert token.balanceOf(account) < 1e13
    else:
        assert pytest.approx(token.balanceOf(account), rel=1e-7) == accountBalanceBefore - amount
    assert wfCash.balanceOf(account) == fCashAmount

    # Test redemption:
    accountBalanceBefore = token.balanceOf(account)
    wfCash.redeemToUnderlying(fCashAmount, account, 0, {"from": account})
    accountBalanceAfter = token.balanceOf(account)
    assert pytest.approx((accountBalanceAfter - accountBalanceBefore) / amount, rel=5e-4) == 0.9985
    
    check_invariants(env, snapshot, currencyId)

def wrapped_fcash_mint_via_asset(env, account, currencyId, fCashAmount):
    env.deployNCTokens()
    env.migrateAll()
    snapshot = snapshot_invariants(env, currencyId)

    markets = env.notional.getActiveMarkets(currencyId)
    wfCashFactory = Contract.from_abi("wfCash Factory", "0x5D051DeB5db151C2172dCdCCD42e6A2953E27261", wfCashFactoryABI)
    txn = wfCashFactory.deployWrapper(currencyId, markets[0][1], {"from": accounts[1]})
    wfCashAddress = txn.return_value
    wfCash = Contract.from_abi('wfCash', wfCashAddress, wfCashABI)

    token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])
    amount = math.floor(wfCash.previewMint(fCashAmount) * 1.0001)
    nwToken = interface.nwTokenInterface(token.address)
    if currencyId == 1:
        nwToken.mint({"value": amount, "from": account})
    else:
        underlying = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        underlying.approve(nwToken, 2 ** 256 - 1, {"from": account})
        nwToken.mint(amount, {"from": account})

    accountBalanceBefore = token.balanceOf(account)
    token.approve(wfCash, 2**256-1, {"from": account})

    # This only works for newly deployed wrappers
    if 'WrapperDeployed' in txn.events:
        wfCash.mintViaAsset(accountBalanceBefore, fCashAmount, account, 0, {"from": account})

        assert token.balanceOf(account) < 1e8
        assert wfCash.balanceOf(account) == fCashAmount

        wfCash.redeemToAsset(fCashAmount, account, 0, {"from": account})
        accountBalanceAfter = token.balanceOf(account)
        assert pytest.approx((accountBalanceAfter/ accountBalanceBefore), rel=5e-4) == 0.9985
    else:
        with brownie.reverts("ERC20: insufficient allowance"):
            wfCash.mintViaAsset(accountBalanceBefore, fCashAmount, account, 0, {"from": account})

    check_invariants(env, snapshot, currencyId)

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

def test_redeem_asset_eth(env):
    redeem_asset(env, accounts[0], 1, 10e18)

def test_redeem_asset_dai(env):
    redeem_asset(env, env.whales["DAI"], 2, 10000e18)

def test_redeem_asset_usdc(env):
    redeem_asset(env, env.whales["USDC"], 3, 10000e6)

def test_redeem_asset_wbtc(env):
    redeem_asset(env, env.whales["WBTC"], 4, 1e8)

def test_wrapped_fcash_underlying_eth(env):
    wrapped_fcash_mint_via_underlying(env, accounts[0], 1, 10e8)

def test_wrapped_fcash_underlying_dai(env):
    wrapped_fcash_mint_via_underlying(env, env.whales['DAI'], 2, 100e8)

def test_wrapped_fcash_underlying_usdc(env):
    wrapped_fcash_mint_via_underlying(env, env.whales['USDC'], 3, 100e8)

def test_wrapped_fcash_underlying_wbtc(env):
    wrapped_fcash_mint_via_underlying(env, env.whales['WBTC'], 4, 0.01e8)

def test_wrapped_fcash_asset_eth(env):
    wrapped_fcash_mint_via_asset(env, accounts[0], 1, 10e8)

def test_wrapped_fcash_asset_dai(env):
    wrapped_fcash_mint_via_asset(env, env.whales['DAI'], 2, 100e8)

def test_wrapped_fcash_asset_usdc(env):
    wrapped_fcash_mint_via_asset(env, env.whales['USDC'], 3, 100e8)

def test_wrapped_fcash_asset_wbtc(env):
    wrapped_fcash_mint_via_asset(env, env.whales['WBTC'], 4, 0.01e8)

def test_no_lost_tokens_due_to_redeem_asset(env):
    currencyId = 2
    fCashAmount = 100e8
    account = env.whales['DAI']

    markets = env.notional.getActiveMarkets(currencyId)
    wfCashFactory = Contract.from_abi("wfCash Factory", "0x5D051DeB5db151C2172dCdCCD42e6A2953E27261", wfCashFactoryABI)
    txn = wfCashFactory.deployWrapper(currencyId, markets[0][1], {"from": accounts[1]})
    wfCashAddress = txn.return_value
    wfCash = Contract.from_abi('wfCash', wfCashAddress, wfCashABI)

    amount = math.floor(wfCash.previewMint(fCashAmount) * 1.000001)
    underlying = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
    underlying.approve(wfCash, 2**256-1, {"from": account})
    wfCash.mintViaUnderlying(amount, fCashAmount, account, 0, {"from": account})

    # Wrapper is already deployed
    assert 'WrapperDeployed' not in txn.events

    # Migrate, now the wfCash asset token is wrong?
    env.deployNCTokens()
    env.migrateAll()
    snapshot = snapshot_invariants(env, currencyId)

    assetToken = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["assetToken"][0])

    # Assert that the account does receive asset tokens
    assert assetToken.balanceOf(account) == 0
    wfCash.redeemToAsset(fCashAmount, account, 0, {"from": account})
    assert wfCash.getAssetToken()[0] == assetToken.address
    assert assetToken.balanceOf(account) > 4400e8

    check_invariants(env, snapshot, currencyId)