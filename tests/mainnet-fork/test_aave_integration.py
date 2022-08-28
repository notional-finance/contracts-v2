import brownie
import pytest
from brownie import MockAggregator, aTokenAggregator
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, nTokenDefaults
from scripts.deployment import TokenType
from scripts.mainnet.EnvironmentConfig import getEnvironment
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
    get_cash_group_with_max_markets,
    get_lend_action,
)

chain = Chain()


@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(autouse=True)
def env():
    e = getEnvironment()
    if e.notional.getLendingPool() != "0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9":
        e.notional.setLendingPool("0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9", {"from": e.owner})

    return e


def list_atoken(env, aToken, underlying):
    aggregator = aTokenAggregator.deploy(
        env.aave["LendingPool"].address, aToken.address, {"from": env.deployer}
    )
    rateOracle = MockAggregator.deploy(18, {"from": env.deployer})
    rateOracle.setAnswer(0.01e18, {"from": env.deployer})

    txn = env.notional.listCurrency(
        (aToken.address, False, TokenType["aToken"], aToken.decimals(), 0),
        (underlying.address, False, TokenType["UnderlyingToken"], underlying.decimals(), 0),
        rateOracle.address,
        False,
        130,
        75,
        108,
        {"from": env.owner},
    )

    currencyId = txn.events["ListCurrency"]["newCurrencyId"]
    env.notional.updateAssetRate(currencyId, aggregator.address, {"from": env.owner})


def enable_atoken_fcash(env, currencyId, aTokenSymbol, underlyingSymbol, initialCash):
    (_, assetRate) = env.notional.getRateStorage(currencyId)

    env.notional.enableCashGroup(
        currencyId,
        assetRate[0],
        get_cash_group_with_max_markets(2),
        underlyingSymbol,
        underlyingSymbol,
        {"from": env.owner},
    )
    env.tokens[aTokenSymbol].approve(
        env.notional.address, 2 ** 255 - 1, {"from": env.whales[aTokenSymbol]}
    )

    env.notional.updateDepositParameters(
        currencyId, *(nTokenDefaults["Deposit"]), {"from": env.owner}
    )
    env.notional.updateInitializationParameters(
        currencyId, *(nTokenDefaults["Initialization"]), {"from": env.owner}
    )
    env.notional.updateTokenCollateralParameters(
        currencyId, *(nTokenDefaults["Collateral"]), {"from": env.owner}
    )
    env.notional.updateIncentiveEmissionRate(
        currencyId, CurrencyDefaults["incentiveEmissionRate"], {"from": env.owner}
    )

    env.notional.batchBalanceAction(
        env.whales[aTokenSymbol].address,
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintNToken", depositActionAmount=initialCash
            )
        ],
        {"from": env.whales[aTokenSymbol]},
    )
    env.notional.initializeMarkets(currencyId, True, {"from": env.owner})


def test_cannot_reset_lending_pool(env):
    with brownie.reverts():
        env.notional.setLendingPool(
            "0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9", {"from": env.owner}
        )


def test_deposit_and_withdraw_underlying_adai(env):
    list_atoken(env, env.tokens["aDAI"], env.tokens["DAI"])
    env.tokens["DAI"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["DAI"]})
    env.notional.depositUnderlyingToken(env.whales["DAI"], 5, 100e18, {"from": env.whales["DAI"]})

    # Notional has an aDAI balance of 100e18
    assert pytest.approx(env.tokens["aDAI"].balanceOf(env.notional.address), abs=10) == 100e18
    # Cash balance is equal to scaled balance of aToken
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["DAI"].address)
    assert Wei(env.tokens["aDAI"].scaledBalanceOf(env.notional.address) / 1e10) == cashBalance

    daiBalanceBefore = env.tokens["DAI"].balanceOf(env.whales["DAI"].address)
    env.notional.withdraw(5, cashBalance, True, {"from": env.whales["DAI"]})
    daiBalanceAfter = env.tokens["DAI"].balanceOf(env.whales["DAI"].address)

    # Should have accrued some interest between blocks
    assert daiBalanceAfter - daiBalanceBefore > 100e18
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["DAI"].address)
    assert cashBalance == 0


def test_deposit_and_withdraw_underlying_ausdc(env):
    list_atoken(env, env.tokens["aUSDC"], env.tokens["USDC"])
    env.tokens["USDC"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["USDC"]})
    env.notional.depositUnderlyingToken(
        env.whales["USDC"], 5, 1_000_000e6, {"from": env.whales["USDC"]}
    )

    # Notional has an aUSDC balance of 100e6
    assert pytest.approx(env.tokens["aUSDC"].balanceOf(env.notional.address), abs=1) == 1_000_000e6
    # Cash balance is equal to scaled balance of aToken
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["USDC"].address)
    assert Wei(env.tokens["aUSDC"].scaledBalanceOf(env.notional.address) * 1e2) == cashBalance

    balanceBefore = env.tokens["USDC"].balanceOf(env.whales["USDC"].address)
    env.notional.withdraw(5, cashBalance, True, {"from": env.whales["USDC"]})
    balanceAfter = env.tokens["USDC"].balanceOf(env.whales["USDC"].address)

    # Should have accrued some interest between blocks
    assert balanceAfter - balanceBefore > 1_000_000e6
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["USDC"].address)
    assert cashBalance == 0


def test_deposit_and_withdraw_asset_adai(env):
    list_atoken(env, env.tokens["aDAI"], env.tokens["DAI"])
    env.tokens["aDAI"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["aDAI"]})
    env.notional.depositAssetToken(env.whales["aDAI"], 5, 100e18, {"from": env.whales["aDAI"]})

    # Notional has an aDAI balance of 100e18
    assert env.tokens["aDAI"].balanceOf(env.notional.address) == 100e18
    # Cash balance is equal to scaled balance of aToken
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["aDAI"].address)
    assert Wei(env.tokens["aDAI"].scaledBalanceOf(env.notional.address) / 1e10) == cashBalance

    txn = env.notional.withdraw(5, cashBalance, False, {"from": env.whales["aDAI"]})

    # Should have accrued some interest between blocks inside Notional
    # NOTE: using a before and after balance check isn't that informative because the
    # aDAI whale is accruing a lot of interest as blocks increase
    assert txn.events["Transfer"]["value"] > 100e18
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["aDAI"].address)
    assert cashBalance == 0


def test_deposit_and_withdraw_asset_ausdc(env):
    list_atoken(env, env.tokens["aUSDC"], env.tokens["USDC"])
    env.tokens["aUSDC"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["aUSDC"]})
    env.notional.depositAssetToken(
        env.whales["aUSDC"], 5, 1_000_000e6, {"from": env.whales["aUSDC"]}
    )

    # Notional has an aUSDC balance of 100e18
    assert pytest.approx(env.tokens["aUSDC"].balanceOf(env.notional.address), abs=1) == 1_000_000e6
    # Cash balance is equal to scaled balance of aToken
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["aUSDC"].address)
    assert Wei(env.tokens["aUSDC"].scaledBalanceOf(env.notional.address) * 1e2) == cashBalance

    txn = env.notional.withdraw(5, cashBalance, False, {"from": env.whales["aUSDC"]})

    # Should have accrued some interest between blocks inside Notional
    # NOTE: using a before and after balance check isn't that informative because the
    # aUSDC whale is accruing a lot of interest as blocks increase
    assert txn.events["Transfer"]["value"] > 1_000_000e6
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["aUSDC"].address)
    assert cashBalance == 0


def test_borrow_ausdc(env, accounts):
    list_atoken(env, env.tokens["aUSDC"], env.tokens["USDC"])
    enable_atoken_fcash(env, 5, "aUSDC", "USDC", 50_000_000e6)
    borrowAction = get_balance_trade_action(
        5,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=5e18)
    balanceBefore = env.tokens["USDC"].balanceOf(accounts[4])
    env.notional.batchBalanceAndTradeAction(
        accounts[4], [collateral, borrowAction], {"from": accounts[4], "value": 5e18}
    )
    balanceAfter = env.tokens["USDC"].balanceOf(accounts[4])
    balanceChange = balanceAfter - balanceBefore
    assert 98e6 < balanceChange and balanceChange < 100e6


def test_borrow_adai(env, accounts):
    list_atoken(env, env.tokens["aDAI"], env.tokens["DAI"])
    enable_atoken_fcash(env, 5, "aDAI", "DAI", 10_000_000e18)
    borrowAction = get_balance_trade_action(
        5,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=5e18)
    balanceBefore = env.tokens["DAI"].balanceOf(accounts[4])
    env.notional.batchBalanceAndTradeAction(
        accounts[4], [collateral, borrowAction], {"from": accounts[4], "value": 5e18}
    )
    balanceAfter = env.tokens["DAI"].balanceOf(accounts[4])
    balanceChange = balanceAfter - balanceBefore
    assert 98e18 < balanceChange and balanceChange < 100e18


def test_lend_and_settle_adai(env):
    list_atoken(env, env.tokens["aDAI"], env.tokens["DAI"])
    enable_atoken_fcash(env, 5, "aDAI", "DAI", 10_000_000e18)
    lendAction = get_balance_trade_action(
        5,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    env.tokens["DAI"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["DAI"]})
    balanceBefore = env.tokens["DAI"].balanceOf(env.whales["DAI"])
    env.notional.batchBalanceAndTradeAction(
        env.whales["DAI"].address, [lendAction], {"from": env.whales["DAI"]}
    )
    balanceAfter = env.tokens["DAI"].balanceOf(env.whales["DAI"])
    balanceChange = balanceBefore - balanceAfter
    assert 98e18 < balanceChange and balanceChange < 100e18

    chain.mine(1, chain.time() + SECONDS_IN_QUARTER)
    env.notional.initializeMarkets(5, False, {"from": env.owner})

    env.notional.settleAccount(env.whales["DAI"].address, {"from": env.owner})
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["DAI"].address)

    balanceBefore = env.tokens["DAI"].balanceOf(env.whales["DAI"])
    env.notional.withdraw(5, cashBalance, True, {"from": env.whales["DAI"]})
    balanceAfter = env.tokens["DAI"].balanceOf(env.whales["DAI"])
    balanceChange = balanceAfter - balanceBefore
    assert 100e18 < balanceChange and balanceChange < 100.1e18


def test_lend_and_settle_ausdc(env):
    list_atoken(env, env.tokens["aUSDC"], env.tokens["USDC"])
    enable_atoken_fcash(env, 5, "aUSDC", "USDC", 10_000_000e6)
    lendAction = get_balance_trade_action(
        5,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100_000e8, "minSlippage": 0}],
        depositActionAmount=100_000e6,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    env.tokens["USDC"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["USDC"]})
    balanceBefore = env.tokens["USDC"].balanceOf(env.whales["USDC"])
    env.notional.batchBalanceAndTradeAction(
        env.whales["USDC"].address, [lendAction], {"from": env.whales["USDC"]}
    )
    balanceAfter = env.tokens["USDC"].balanceOf(env.whales["USDC"])
    balanceChange = balanceBefore - balanceAfter
    assert 98_000e6 < balanceChange and balanceChange < 100_000e6

    chain.mine(1, chain.time() + SECONDS_IN_QUARTER)
    env.notional.initializeMarkets(5, False, {"from": env.owner})

    env.notional.settleAccount(env.whales["USDC"].address, {"from": env.owner})
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["USDC"].address)

    balanceBefore = env.tokens["USDC"].balanceOf(env.whales["USDC"])
    env.notional.withdraw(5, cashBalance, True, {"from": env.whales["USDC"]})
    balanceAfter = env.tokens["USDC"].balanceOf(env.whales["USDC"])
    balanceChange = balanceAfter - balanceBefore
    assert 100_000e6 < balanceChange and balanceChange < 100_000.1e6


def test_batch_lend_adai(env):
    list_atoken(env, env.tokens["aDAI"], env.tokens["DAI"])
    enable_atoken_fcash(env, 5, "aDAI", "DAI", 10_000_000e18)
    lendAction = get_lend_action(
        5,
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        False,
    )

    env.tokens["aDAI"].approve(env.notional.address, 2 ** 255 - 1, {"from": env.whales["aDAI"]})
    balanceBefore = env.tokens["aDAI"].balanceOf(env.whales["aDAI"])
    env.notional.batchLend(env.whales["aDAI"].address, [lendAction], {"from": env.whales["aDAI"]})
    balanceAfter = env.tokens["aDAI"].balanceOf(env.whales["aDAI"])
    balanceChange = balanceBefore - balanceAfter
    assert 98e18 < balanceChange and balanceChange < 100e18

    chain.mine(1, chain.time() + SECONDS_IN_QUARTER)
    env.notional.initializeMarkets(5, False, {"from": env.owner})

    env.notional.settleAccount(env.whales["aDAI"].address, {"from": env.owner})
    (cashBalance, _, _) = env.notional.getAccountBalance(5, env.whales["aDAI"].address)

    balanceBefore = env.tokens["aDAI"].balanceOf(env.whales["aDAI"])
    env.notional.withdraw(5, cashBalance, False, {"from": env.whales["aDAI"]})
    balanceAfter = env.tokens["aDAI"].balanceOf(env.whales["aDAI"])
    balanceChange = balanceAfter - balanceBefore
    assert 100e18 < balanceChange and balanceChange < 100.1e18
