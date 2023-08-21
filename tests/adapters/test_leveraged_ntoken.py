import brownie
from brownie.network import Chain
import pytest
from tests.constants import SECONDS_IN_DAY
from tests.helpers import get_balance_action, get_balance_trade_action, initialize_environment
from tests.stateful.invariants import check_system_invariants
from brownie.test import given, strategy

chain = Chain()

@pytest.fixture(scope="module", autouse=True)
def environment(accounts, LeveragedNTokenAdapter):
    env = initialize_environment(accounts)
    callback = LeveragedNTokenAdapter.deploy(env.notional.address, {"from": accounts[0]})
    env.notional.updateAuthorizedCallbackContract(callback, True, {"from": env.notional.owner()})
    return (env, callback)

@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

def test_fails_on_fc_check(environment, accounts):
    (env, callback) = environment
    # Crashes the RPC with a string length error
    with brownie.reverts("Insufficient free collateral"):
        callback.doLeveragedNToken(
            [
                get_balance_trade_action(
                    1,
                    "DepositUnderlying",
                    [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 1e8, "maxSlippage": 0}],
                    depositActionAmount=0.1e18,
                ),
            ],
            0,
            {"from": accounts[1], "value": 0.1e18}
        )

    env.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    with brownie.reverts("Insufficient free collateral"):
        callback.doLeveragedNToken(
            [
                get_balance_trade_action(
                    1,
                    "DepositUnderlying",
                    [],
                    depositActionAmount=1e18,
                    
                ),
            ],
            1_000e8,
            {"from": accounts[1], "value": 1e18}
        )

def test_fails_on_direct_call(environment, accounts):
    (_, callback) = environment
    with brownie.reverts("Unauthorized callback"):
        callback.notionalCallback(accounts[0], accounts[0], "")

def test_fails_on_multiple_borrow_actions(environment, accounts):
    (_, callback) = environment
    with brownie.reverts():
        callback.doLeveragedNToken(
            [
            get_balance_trade_action(
                1,
                "None",  # No balance
                [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
            ),
            get_balance_trade_action(
                2,
                "None",  # No balance
                [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
            ),
            ],
            0,
            {"from": accounts[1]}
        )

    with brownie.reverts():
        callback.doLeveragedNToken(
            [
            get_balance_trade_action(
                1,
                "None",  # No balance
                [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
            ),
            ],
            0,
            {"from": accounts[1]}
        )

def test_fails_on_prime_borrow(environment, accounts):
    (_, callback) = environment
    with brownie.reverts("No Prime Borrow"):
        callback.doLeveragedNToken(
            [
                get_balance_trade_action(
                    1,
                    "DepositUnderlying",
                    [],
                    depositActionAmount=1e18,
                    
                ),
            ],
            100e8,
            {"from": accounts[1], "value": 1e18}
        )

@given(
    currencyId=strategy("int", min_value=1, max_value=2),
    borrowPrime=strategy("bool")
)
def test_succeeds_on_new_account(environment, accounts, currencyId, borrowPrime):
    (env, callback) = environment
    if borrowPrime:
        env.notional.enablePrimeBorrow(True, {"from": accounts[1]})

    callback.doLeveragedNToken(
        [
            get_balance_trade_action(
                currencyId,
                "DepositUnderlying",
                [] if borrowPrime else [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 1e8, "maxSlippage": 0}],
                depositActionAmount=1e18,
                
            ),
        ],
        env.notional.convertUnderlyingToPrimeCash(currencyId, 2e18) if borrowPrime else 0,
        {"from": accounts[1], "value": 1e18 if currencyId == 1 else 0}
    )
    (cashBalance, nToken, _) = env.notional.getAccountBalance(currencyId, accounts[1])
    portfolio = env.notional.getAccount(accounts[1])['portfolio']

    if borrowPrime:
        assert len(portfolio) == 0
        assert pytest.approx(env.notional.convertCashBalanceToExternal(currencyId, cashBalance, True)) == -1e18
    else:
        assert len(portfolio) == 1
        assert portfolio[0][3] == -1e8
        assert cashBalance == 0

    assert 1.90e18 < env.notional.convertNTokenToUnderlying(currencyId, nToken) <= 2e18

    check_system_invariants(env, accounts)

def test_succeeds_on_account_with_cash(environment, accounts):
    (env, callback) = environment
    env.notional.depositUnderlyingToken(accounts[1], 1, 1e18, {"from": accounts[1], "value": 1e18})
    callback.doLeveragedNToken(
        [
            get_balance_trade_action(
                1,
                "DepositUnderlying",
                [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 1e8, "maxSlippage": 0}],
                depositActionAmount=1e18,
                
            ),
        ],
        98e8,
        {"from": accounts[1], "value": 1e18}
    )
    (cashBalance, nToken, _) = env.notional.getAccountBalance(1, accounts[1])
    portfolio = env.notional.getAccount(accounts[1])['portfolio']
    assert len(portfolio) == 1
    assert portfolio[0][3] == -1e8
    assert pytest.approx(nToken) == 98e8
    assert pytest.approx(cashBalance, abs=1e8) == 50.7e8

    check_system_invariants(env, accounts)

def test_succeeds_on_account_with_ntokens(environment, accounts):
    (env, callback) = environment
    env.notional.batchBalanceAction(
        accounts[1],
        [
            get_balance_action(
                1, "DepositUnderlyingAndMintNToken", depositActionAmount=1e18
            )
        ],
        {"from": accounts[1], "value": 1e18},
    )
    noteBalance = env.noteERC20.balanceOf(accounts[1])
    chain.mine(timedelta=SECONDS_IN_DAY)

    env.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    callback.doLeveragedNToken(
        [
            get_balance_trade_action(
                1,
                "DepositUnderlying",
                [],
                depositActionAmount=1e18,
                
            ),
        ],
        100e8,
        {"from": accounts[1], "value": 1e18}
    )
    (_, nToken, _) = env.notional.getAccountBalance(1, accounts[1])
    assert pytest.approx(nToken) == 150e8
    noteBalanceAfter = env.noteERC20.balanceOf(accounts[1])
    assert noteBalanceAfter > noteBalance

    check_system_invariants(env, accounts)
