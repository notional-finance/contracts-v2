import pytest
import json
import brownie
import math
import eth_abi
from brownie import Contract, accounts, interface, Wei, NotionalV2FlashLiquidator
from brownie.network.state import Chain
from brownie.convert import to_bytes
from scripts.CTokenMigrationEnvironment import cTokenMigrationEnvironment
from tests.helpers import get_balance_action

chain = Chain()

wfCashABI = json.load(open("abi/WrappedfCash.json"))
wfCashFactoryABI = json.load(open("abi/WrappedfCashFactory.json"))

@pytest.fixture(scope="module", autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

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

def test_redeem_underlying_to_zero(env):
    env.deployNCTokens()
    env.migrateAll()

    for i in range(1, 5):
        if i != 1:
            underlying = interface.IERC20(env.notional.getCurrencyAndRates(i)["underlyingToken"][0])
        asset = interface.IERC20(env.notional.getCurrencyAndRates(i)["assetToken"][0])
        nwAsset = interface.nwTokenInterface(env.notional.getCurrencyAndRates(i)["assetToken"][0])

        balanceOfAssetBefore = underlying.balanceOf(asset.address) if i != 1 else asset.balance()
        balanceOfNotionalBefore = underlying.balanceOf(env.notional.address) if i != 1 else env.notional.balance()

        with brownie.reverts("ERC20: burn amount exceeds balance"):
            nwAsset.redeemUnderlying(balanceOfAssetBefore, {"from": env.notional})

        # Assert that only dust remains at a full redemption
        if i == 1 or underlying.decimals() == 18:
            dust = 1e10
        elif underlying.decimals() == 8:
            dust = 1
        elif underlying.decimals() == 6:
            dust = 1

        nwAsset.redeemUnderlying(balanceOfAssetBefore - dust, {"from": env.notional})

        remainingAssetBalance = underlying.balanceOf(asset.address) if i != 1 else asset.balance()
        balanceOfNotionalAfter = underlying.balanceOf(env.notional.address) if i != 1 else env.notional.balance()

        assert remainingAssetBalance == dust
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

def mint_ntoken_underlying(env, account, currencyId, depositAmount):
    env.deployNCTokens()
    env.migrateAll()

    if currencyId == 1:
        balanceBefore = account.balance()
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        token.approve(env.notional, 2**256-1, {"from": account})
        balanceBefore = token.balanceOf(account)

    env.notional.batchBalanceAction(
        account, [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=depositAmount
            )
        ], {"from": account, "value": depositAmount if currencyId == 1 else 0}
    )
    nTokenBalance = env.notional.getAccountBalance(currencyId, account)['nTokenBalance']
    assert nTokenBalance > 0

    if currencyId == 1:
        balanceAfter = account.balance()
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        balanceAfter = token.balanceOf(account)

    assert balanceBefore - balanceAfter == depositAmount

    env.notional.batchBalanceAction(
        account, [
            get_balance_action(
                currencyId,
                "RedeemNToken",
                depositActionAmount=nTokenBalance,
                withdrawEntireCashBalance=True,
                redeemToUnderlying=True
            )
        ], {"from": account}
    )
    nTokenBalance = env.notional.getAccountBalance(currencyId, account)['nTokenBalance']
    assert nTokenBalance == 0

    if currencyId == 1:
        balanceAfter = account.balance()
    else:
        token = interface.IERC20(env.notional.getCurrencyAndRates(currencyId)["underlyingToken"][0])
        balanceAfter = token.balanceOf(account)
    
    assert 0 < balanceBefore - balanceAfter and balanceBefore - balanceAfter < depositAmount * 0.0003

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

def test_mint_and_redeem_neth(env):
    mint_ntoken_underlying(env, accounts[0], 1, 10e18)

def test_mint_and_redeem_ndai(env):
    mint_ntoken_underlying(env, env.whales['DAI'], 2, 1_000e18)

def test_mint_and_redeem_nusdc(env):
    mint_ntoken_underlying(env, env.whales['USDC'], 3, 1_000e6)

def test_mint_and_redeem_nwbtc(env):
    mint_ntoken_underlying(env, env.whales['WBTC'], 4, 0.01e8)

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

def getAssetExchangeRateAddress(env, currencyId):
    assetExchangeRateAddress = env.notional.getRateStorage(currencyId)[1][0]
    return assetExchangeRateAddress


def getAssetExchangeRate(env, currencyId):
    assetExchangeRateAddress = getAssetExchangeRateAddress(env, currencyId)
    assetExchangeRateDecimals = env.notional.getRateStorage(currencyId)[1][1]
    assetExchangeRateDecimals = pow(10, int(assetExchangeRateDecimals))
    assetExchangeRate = interface.AssetRateAdapter(assetExchangeRateAddress).getExchangeRateView()
    assetExchangeRate = assetExchangeRate / assetExchangeRateDecimals
    return assetExchangeRate / 1e10 # Decimals to be set as a variable

def underlyingPrecision(env, currencyId):
    if (currencyId == 1):
        return 1e18
    else:
        params = env.notional.getCurrency(currencyId)[1]
        underlyingDecimals = params[2]
        return underlyingDecimals       
    
def pathCalldataExactOut(fromAddr, toAddr):
    packedEncoder = eth_abi.codec.ABIEncoder(eth_abi.registry.registry_packed)
    return packedEncoder.encode_abi(
        ["address", "uint24", "address", "uint24", "address"], 
        [toAddr, 3000, "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", 3000, fromAddr]
    )

def collateralCalldata(
    env,
    localCurrency, 
    account, 
    collateralCurrency, 
    amount, 
    liquidator
):
    router = interface.ISwapRouter("0xE592427A0AEce92De3Edee1F18E0157C05861564")
    localUnderlying = env.notional.getCurrencyAndRates(localCurrency)["underlyingToken"][0]
    collateralUnderlying = env.notional.getCurrencyAndRates(collateralCurrency)["underlyingToken"][0]
    liqCalldata = eth_abi.encode_abi(
        ['(address,uint16,address,uint16,address,address,uint128,uint96,(address,bytes))'],
        [[
            account, 
            localCurrency, 
            localUnderlying, 
            collateralCurrency,  
            env.notional.getCurrencyAndRates(collateralCurrency)["assetToken"][0],
            collateralUnderlying,
            0,
            0,
            [
                router.address,
                to_bytes(router.exactOutput.encode_input([
                    pathCalldataExactOut(collateralUnderlying, localUnderlying),
                    liquidator,
                    chain.time() + 20000,
                    math.floor(amount * 1.001),
                    Wei(2**256-1)
                ]), "bytes")
            ]
        ]]
    )
    return eth_abi.encode_abi(
        ['(uint8,bool,bool,bytes)'],
        [[1, False, False, liqCalldata]]
    )


def test_liquidation_eth(env):
    env.deployNCTokens()
    env.migrateAll()
    
    liquidator = NotionalV2FlashLiquidator.deploy(
        env.notional,
        "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9", # Aave 
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH
        "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0", # wstETH
        env.deployer,
        "0xE592427A0AEce92De3Edee1F18E0157C05861564",  # UniV3,
        "0xE592427A0AEce92De3Edee1F18E0157C05861564",  # UniV3,
        {"from": env.deployer}
    )
    liquidator.enableCurrencies([1,2,3,4], {"from": env.deployer})

    env.notional.updateETHRate(
        2, 
        "0x6085B0a8f4c7ffA2E8CA578037792D6535d1E29B", 
        False, 
        130, 
        75, 
        120, 
        {"from": env.notional.owner()}
    )

    localCurrencyRequired = env.notional.calculateCollateralCurrencyLiquidation.call(
        "0x940d92f24547a87ea4fd59d5c78a842bee41bb57",
        3, 
        2, 
        0, 
        0, 
        {"from": env.deployer} 
    )[0]
    loanAmount = localCurrencyRequired * underlyingPrecision(env, 3) * getAssetExchangeRate(env, 3) * 1.2 / 1e8

    ret = liquidator.flashLoan.call(
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 
        loanAmount, 
        collateralCalldata(
            env, 
            3, 
            "0x940d92f24547a87ea4fd59d5c78a842bee41bb57", 
            2, 
            loanAmount, 
            liquidator
        ), "0x6b175474e89094c44da98b954eedeac495271d0f"
    )

    assert pytest.approx(ret[0], rel=1e-2) == 22659514797
    assert pytest.approx(ret[1], rel=1e-2) == 1685441876267557686652
