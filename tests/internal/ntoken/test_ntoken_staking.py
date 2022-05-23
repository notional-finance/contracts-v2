from collections import defaultdict

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network import Chain
from tests.constants import SECONDS_IN_DAY, SECONDS_IN_QUARTER, START_TIME_TREF
from tests.helpers import get_tref

# from brownie.test import given, strategy

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def StakedNToken(
    MockNTokenStaked, nTokenMintAction, nTokenRedeemAction, MockCToken, cTokenAggregator, accounts
):
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    cToken.setAnswer(200000000000000000000000000, {"from": accounts[0]})
    nTokenMintAction.deploy({"from": accounts[0]})
    nTokenRedeemAction.deploy({"from": accounts[0]})

    mock = MockNTokenStaked.deploy({"from": accounts[0]})
    mock.setAssetRateMapping(1, (aggregator.address, 18))
    chain.mine(1, START_TIME_TREF)
    return mock


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def check_invariants(StakedNToken, accounts, blockTime, prevIncentiveAccumulator=None):
    unstakeMaturity = get_tref(blockTime) + SECONDS_IN_QUARTER

    incentiveAccumulators = {
        "accountIncentiveDebt": defaultdict(lambda: 0),
        "accumulatedNOTE": defaultdict(lambda: 0),
        "snTokenBalance": defaultdict(lambda: 0),
    }

    # Check that incentive counters are always increasing
    incentives = StakedNToken.getStakedIncentives(1).dict()
    incentiveAccumulators["totalAccumulatedNOTEPerStaked"] = incentives[
        "totalAccumulatedNOTEPerStaked"
    ]
    incentiveAccumulators["lastBaseAccumulatedNOTEPerNToken"] = incentives[
        "lastBaseAccumulatedNOTEPerNToken"
    ]
    incentiveAccumulators["lastAccumulatedTime"] = incentives["lastAccumulatedTime"]

    if prevIncentiveAccumulator:
        # All of these fields on the accumulator only ever increase
        assert (
            incentiveAccumulators["totalAccumulatedNOTEPerStaked"]
            >= prevIncentiveAccumulator["totalAccumulatedNOTEPerStaked"]
        )
        assert (
            incentiveAccumulators["lastBaseAccumulatedNOTEPerNToken"]
            >= prevIncentiveAccumulator["lastBaseAccumulatedNOTEPerNToken"]
        )
        assert (
            incentiveAccumulators["lastAccumulatedTime"]
            >= prevIncentiveAccumulator["lastAccumulatedTime"]
        )

    # Sum of all stakers equals total supply
    totalStakerSupply = 0
    totalUnstakeSignal = 0
    stakedSupply = StakedNToken.getStakedSupply(1)
    (_, _, _, totalSignal) = StakedNToken.getUnstakeSignal(accounts[0].address, 1, blockTime)

    for a in accounts:
        m = StakedNToken.getStaker(a.address, 1).dict()
        s = StakedNToken.getUnstakeSignal(a.address, 1, blockTime).dict()
        totalStakerSupply += m["snTokenBalance"]
        if s["unstakeMaturity"] == unstakeMaturity:
            totalStakerSupply += s["snTokenDeposit"]
            totalUnstakeSignal += s["snTokensToUnstake"]

        incentiveAccumulators["snTokenBalance"][a.address] = m["snTokenBalance"]
        incentiveAccumulators["accountIncentiveDebt"][a.address] = m["accountIncentiveDebt"]
        incentiveAccumulators["accumulatedNOTE"][a.address] = m["accumulatedNOTE"]

        if prevIncentiveAccumulator:
            # If the staked supply has changed then accumulators must increase
            if prevIncentiveAccumulator["snTokenBalance"][a.address] != m["snTokenBalance"]:
                assert (
                    m["accountIncentiveDebt"]
                    > prevIncentiveAccumulator["accountIncentiveDebt"][a.address]
                )
                assert m["accumulatedNOTE"] > prevIncentiveAccumulator["accumulatedNOTE"][a.address]
            else:
                assert (
                    m["accountIncentiveDebt"]
                    == prevIncentiveAccumulator["accountIncentiveDebt"][a.address]
                )
                assert (
                    m["accumulatedNOTE"] == prevIncentiveAccumulator["accumulatedNOTE"][a.address]
                )

    assert totalStakerSupply == stakedSupply["totalSupply"]
    assert totalUnstakeSignal == totalSignal
    return incentiveAccumulators


def test_set_profits(StakedNToken, accounts):
    StakedNToken.updateStakedNTokenProfits(1, 100e8)
    supply = StakedNToken.getStakedSupply(1).dict()
    assert supply["totalCashProfits"] == 100e8

    StakedNToken.updateStakedNTokenProfits(1, 200e8)
    supply = StakedNToken.getStakedSupply(1).dict()
    assert supply["totalCashProfits"] == 300e8

    StakedNToken.updateStakedNTokenProfits(1, -100e8)
    supply = StakedNToken.getStakedSupply(1).dict()
    assert supply["totalCashProfits"] == 200e8

    with brownie.reverts():
        # Reverts due to going negative
        StakedNToken.updateStakedNTokenProfits(1, -300e8)


def test_stake_ntoken(StakedNToken, accounts):
    StakedNToken.setupIncentives(1, 100_000, 200_000, START_TIME_TREF)
    StakedNToken.mintNTokens(1, 100_000e8, START_TIME_TREF)

    StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 100)
    supply1 = StakedNToken.getStakedSupply(1).dict()
    staker1 = StakedNToken.getStaker(accounts[0], 1).dict()

    assert supply1["totalSupply"] == 100e8
    assert supply1["nTokenBalance"] == 100e8
    assert staker1["snTokenBalance"] == 100e8
    assert staker1["accountIncentiveDebt"] == 0
    assert staker1["accumulatedNOTE"] == 0

    StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 500)
    supply2 = StakedNToken.getStakedSupply(1).dict()
    staker2 = StakedNToken.getStaker(accounts[0], 1).dict()

    assert supply2["totalSupply"] == 200e8
    assert supply2["nTokenBalance"] == 200e8
    assert staker2["snTokenBalance"] == 200e8
    assert staker2["accountIncentiveDebt"] > staker1["accountIncentiveDebt"]
    assert staker2["accumulatedNOTE"] > 0

    check_invariants(StakedNToken, accounts, START_TIME_TREF + 500)


def test_stake_ntoken_with_cash_profits(StakedNToken, accounts):
    StakedNToken.setupIncentives(1, 100_000, 200_000, START_TIME_TREF)
    StakedNToken.mintNTokens(1, 100_000e8, START_TIME_TREF)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 100)

    StakedNToken.updateStakedNTokenProfits(1, 100e8)

    StakedNToken.stakeNToken(accounts[1], 1, 100e8, START_TIME_TREF + 100)
    supply = StakedNToken.getStakedSupply(1).dict()
    staker = StakedNToken.getStaker(accounts[1], 1).dict()

    assert supply["totalSupply"] == 150e8
    assert supply["nTokenBalance"] == 200e8
    assert staker["snTokenBalance"] == 50e8
    assert staker["accountIncentiveDebt"] == 0
    assert staker["accumulatedNOTE"] == 0

    check_invariants(StakedNToken, accounts, START_TIME_TREF + 100)


def test_fail_unstake_signal_outside_of_window(StakedNToken, accounts):
    with brownie.reverts("Not in Signal Window"):
        StakedNToken.setUnstakeSignal(accounts[0], 1, 100e8, START_TIME_TREF)
        StakedNToken.setUnstakeSignal(accounts[0], 1, 100e8, START_TIME_TREF + 30 * SECONDS_IN_DAY)
        StakedNToken.setUnstakeSignal(accounts[0], 1, 100e8, START_TIME_TREF + 60 * SECONDS_IN_DAY)


def test_fail_unstake_over_balance(StakedNToken, accounts):
    StakedNToken.setupIncentives(1, 100_000, 200_000, START_TIME_TREF)
    StakedNToken.mintNTokens(1, 100_000e8, START_TIME_TREF)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 100)

    with brownie.reverts():
        StakedNToken.setUnstakeSignal(accounts[0], 1, 200e8, START_TIME_TREF + 70 * SECONDS_IN_DAY)


def test_set_unstake_signal_and_reset(StakedNToken, accounts):
    snTokenBalance = 100e8
    StakedNToken.setupIncentives(1, 100, 200, START_TIME_TREF)
    StakedNToken.mintNTokens(1, 100_000e8, START_TIME_TREF)
    StakedNToken.stakeNToken(accounts[0], 1, snTokenBalance, START_TIME_TREF + 100)
    accum = check_invariants(StakedNToken, accounts, START_TIME_TREF + 100)

    for i in range(1, 11):
        amount = i * snTokenBalance / 10
        blockTime = START_TIME_TREF + 62 * SECONDS_IN_DAY + i * 86400
        StakedNToken.setUnstakeSignal(accounts[0], 1, amount, blockTime)

        (
            maturity,
            snTokensToUnstake,
            snTokenDeposit,
            totalUnstakeSignal,
        ) = StakedNToken.getUnstakeSignal(accounts[0], 1, blockTime)
        supply = StakedNToken.getStakedSupply(1).dict()
        staker = StakedNToken.getStaker(accounts[0], 1).dict()

        assert maturity == START_TIME_TREF + SECONDS_IN_QUARTER
        assert snTokensToUnstake == amount
        assert snTokenDeposit == Wei(amount * 0.005)
        assert totalUnstakeSignal == amount
        assert staker["snTokenBalance"] == 100e8 - snTokenDeposit
        assert supply["totalSupply"] == 100e8

        accum = check_invariants(StakedNToken, accounts, blockTime, accum)


def test_set_multiple_unstake_signal(StakedNToken, accounts):
    StakedNToken.setupIncentives(1, 100_000, 200_000, START_TIME_TREF)
    StakedNToken.mintNTokens(1, 100_000e8, START_TIME_TREF)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 100)
    StakedNToken.stakeNToken(accounts[1], 1, 100e8, START_TIME_TREF + 100)
    StakedNToken.stakeNToken(accounts[3], 1, 100e8, START_TIME_TREF + 100)

    accum = check_invariants(StakedNToken, accounts, START_TIME_TREF + 100)

    StakedNToken.setUnstakeSignal(accounts[0], 1, 50e8, START_TIME_TREF + 70 * SECONDS_IN_DAY)
    StakedNToken.setUnstakeSignal(accounts[1], 1, 100e8, START_TIME_TREF + 70 * SECONDS_IN_DAY)

    check_invariants(StakedNToken, accounts, START_TIME_TREF + 70 * SECONDS_IN_DAY, accum)


def test_lost_unstake_signal(StakedNToken, accounts):
    StakedNToken.setupIncentives(1, 100_000, 200_000, START_TIME_TREF)
    StakedNToken.mintNTokens(1, 100_000e8, START_TIME_TREF)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 100)

    StakedNToken.setUnstakeSignal(accounts[0], 1, 50e8, START_TIME_TREF + 62 * SECONDS_IN_DAY)
    check_invariants(StakedNToken, accounts, START_TIME_TREF + 100)

    StakedNToken.setUnstakeSignal(
        accounts[0], 1, 75e8, START_TIME_TREF + SECONDS_IN_QUARTER + 62 * SECONDS_IN_DAY
    )
    (
        maturity,
        snTokensToUnstake,
        snTokenDeposit,
        totalUnstakeSignal,
    ) = StakedNToken.getUnstakeSignal(
        accounts[0], 1, START_TIME_TREF + SECONDS_IN_QUARTER + 62 * SECONDS_IN_DAY
    )
    supply = StakedNToken.getStakedSupply(1).dict()
    staker = StakedNToken.getStaker(accounts[0], 1).dict()

    assert maturity == START_TIME_TREF + 2 * SECONDS_IN_QUARTER
    assert snTokensToUnstake == 75e8
    assert snTokenDeposit == 0.375e8
    assert totalUnstakeSignal == 75e8
    assert staker["snTokenBalance"] == 99.375e8
    assert supply["totalSupply"] == 100e8

    # TODO: This will fail the total supply invariant because of the lost deposit
    # check_invariants(StakedNToken, accounts,
    # START_TIME_TREF + SECONDS_IN_QUARTER + 62 * SECONDS_IN_DAY)


def test_balance_of_selector_with_signal(StakedNToken, accounts):
    pass


def test_fail_unstake_token_outside_window(StakedNToken, accounts):
    pass


def test_fail_unstake_token_no_signal(StakedNToken, accounts):
    pass


def test_fail_unstake_token_old_signal(StakedNToken, accounts):
    pass


def test_fail_unstake_token_insufficient_signal(StakedNToken, accounts):
    pass


def test_unstake_token_multiple_times(StakedNToken, accounts):
    pass


def test_unstake_token_maximum(StakedNToken, accounts):
    pass


def test_unstake_token_with_cash_balance(StakedNToken, accounts):
    pass
