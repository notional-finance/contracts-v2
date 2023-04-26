import brownie
import pytest
from brownie import accounts
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from scripts.config import CurrencyDefaults, nTokenDefaults
from tests.constants import RATE_PRECISION, SECONDS_IN_QUARTER
from tests.helpers import (
    get_balance_trade_action,
    get_interest_rate_curve,
    get_tref,
    initialize_environment,
)
from tests.stateful.invariants import check_system_invariants

chain = Chain()


def transferTokens(environment, accounts):
    for account in accounts[1:]:
        environment.token["DAI"].transfer(account, 100000e18, {"from": accounts[0]})
        environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": account})
        environment.token["USDC"].transfer(account, 100000e6, {"from": accounts[0]})
        environment.token["USDC"].approve(environment.notional.address, 2 ** 255, {"from": account})


@pytest.fixture(scope="module", autouse=True)
def env(accounts):
    environment = initialize_environment(accounts)
    cashGroup = list(environment.notional.getCashGroup(2))
    # Enable the one year market
    cashGroup[0] = 3
    environment.notional.updateCashGroup(2, cashGroup)

    environment.notional.updateDepositParameters(2, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9])

    environment.notional.updateInterestRateCurve(2, [1, 2, 3], [get_interest_rate_curve()] * 3)
    environment.notional.updateInitializationParameters(2, [0] * 3, [0.5e9, 0.5e9, 0.5e9])

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    environment.notional.initializeMarkets(3, False)

    transferTokens(environment, accounts)

    return environment


def check_liquidation_invariants(environment, liquidatedAccount, fcBefore):
    (fc, netLocal) = environment.notional.getFreeCollateral(liquidatedAccount)
    assert fc > fcBefore[0]
    # This is not always true, insolvent accounts will be left with negative FC
    # assert fc >= -10

    if len(list(filter(lambda x: x != 0, netLocal))) > 1:
        # Check that net available haven't crossed boundaries for cross currency
        if fcBefore[1][0] > 0:
            assert netLocal[0] >= 0
        else:
            assert netLocal[0] <= 0

        if fcBefore[1][1] > 0:
            assert netLocal[1] >= 0
        else:
            assert netLocal[1] <= 0

    check_system_invariants(environment, accounts)
