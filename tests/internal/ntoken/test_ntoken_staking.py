from collections import defaultdict

import brownie
import pytest
from brownie.network import Chain
from brownie.test import given, strategy
from tests.constants import SECONDS_IN_DAY, SECONDS_IN_QUARTER, START_TIME_TREF
from tests.helpers import get_tref

# from brownie.convert.datatypes import Wei

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def StakedNToken(MockNTokenStaked, nTokenMintAction, nTokenRedeemAction, accounts):
    nTokenMintAction.deploy({"from": accounts[0]})
    nTokenRedeemAction.deploy({"from": accounts[0]})
    mock = MockNTokenStaked.deploy({"from": accounts[0]})
    chain.mine(1, START_TIME_TREF)
    return mock


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def check_invariants(StakedNToken, accounts, blockTime, prevIncentiveAccumulator=None):
    tRef = get_tref(blockTime)
    # This should never be set
    zeroMaturity = StakedNToken.getStakedMaturityIncentive(1, 0)
    assert zeroMaturity == (0, 0, 0, 0)
    incentiveAccumulators = {
        "accountIncentiveDebt": defaultdict(lambda: 0),
        "accumulatedNOTE": defaultdict(lambda: 0),
        "stakedSupply": defaultdict(lambda: 0),
        "termLastAccumulatedTime": defaultdict(lambda: 0),
        "termAccumulatedNOTEPerStaked": defaultdict(lambda: 0),
    }

    # Check some reasonable range of dates
    stakedSupply = StakedNToken.getStakedNTokenSupply(1).dict()
    incentiveAccumulators["baseAccumulatedNOTEPerStaked"] = stakedSupply[
        "baseAccumulatedNOTEPerStaked"
    ]
    incentiveAccumulators["lastBaseAccumulatedNOTEPerNToken"] = stakedSupply[
        "lastBaseAccumulatedNOTEPerNToken"
    ]

    if prevIncentiveAccumulator:
        assert (
            stakedSupply["baseAccumulatedNOTEPerStaked"]
            >= prevIncentiveAccumulator["baseAccumulatedNOTEPerStaked"]
        )
        assert (
            stakedSupply["lastBaseAccumulatedNOTEPerNToken"]
            >= prevIncentiveAccumulator["lastBaseAccumulatedNOTEPerNToken"]
        )

    # Sum of all stakers equals total supply
    totalStakerSupply = 0
    termSupplyCalc = defaultdict(lambda: 0)
    for a in accounts:
        m = StakedNToken.getNTokenStaker(a.address, 1).dict()
        totalStakerSupply += m["stakedNTokenBalance"]

        # Sum up the per term supply
        termSupplyCalc[m["unstakeMaturity"]] += m["stakedNTokenBalance"]
        incentiveAccumulators["accountIncentiveDebt"][a.address] = m["accountIncentiveDebt"]
        incentiveAccumulators["accumulatedNOTE"][a.address] = m["accumulatedNOTE"]

        if prevIncentiveAccumulator:
            # If the staked supply has changed then accumulators must increase
            if prevIncentiveAccumulator["stakedSupply"][a.address] != m["stakedNTokenSupply"]:
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

    for i in range(-4, 12):
        m = StakedNToken.getStakedMaturityIncentive(1, tRef + i * SECONDS_IN_QUARTER).dict()
        if blockTime >= m["unstakeMaturity"]:
            # Last accumulated time goes up to maturity and never over
            assert m["lastAccumulatedTime"] == m["unstakeMaturity"] or m["lastAccumulatedTime"] == 0
        else:
            assert m["lastAccumulatedTime"] == blockTime or m["termStakedSupply"] == 0

        incentiveAccumulators["termAccumulatedNOTEPerStaked"][m["unstakeMaturity"]] = m[
            "termAccumulatedNOTEPerStaked"
        ]
        if prevIncentiveAccumulator:
            assert (
                m["termAccumulatedNOTEPerStaked"]
                > prevIncentiveAccumulator["termAccumulatedNOTEPerStaked"][m["unstakeMaturity"]]
            )

    # Last accumulated time on all active terms is equal
    activeTerms = StakedNToken.getStakedMaturityIncentivesFromRef(1, tRef)
    lastAccumulatedTimeSet = set([t[3] for t in activeTerms])
    assert len(lastAccumulatedTimeSet) == 1
    assert lastAccumulatedTimeSet.pop() != 0

    for (i, term) in enumerate(activeTerms):
        # Assert that each active term has the correct total supply
        assert termSupplyCalc[term[0]] == term[2]


def test_fail_staking_maturity_before_blocktime(StakedNToken, accounts):
    with brownie.reverts("Invalid Maturity"):
        # Previous quarter
        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF - SECONDS_IN_QUARTER, START_TIME_TREF + 100
        )

        # Current Tref
        StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF, START_TIME_TREF + 100)

        # Current Tref Equal
        StakedNToken.stakeNToken(accounts[0], 1, 100e8, START_TIME_TREF, START_TIME_TREF)


def test_staking_maturity_must_be_longer(StakedNToken, accounts):
    # Staked to a future maturity
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + 3 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    # Cannot shorten unstake maturity
    with brownie.reverts("Invalid Maturity"):
        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + 1 * SECONDS_IN_QUARTER, START_TIME_TREF + 110
        )

        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + 2 * SECONDS_IN_QUARTER, START_TIME_TREF + 110
        )


def test_cannot_stake_past_max_terms(StakedNToken, accounts):
    with brownie.reverts("Invalid Maturity"):
        StakedNToken.stakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + 5 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
        )


def test_staking_maturity_not_quarter_alignment(StakedNToken, accounts):
    with brownie.reverts("Invalid Maturity"):
        # Future maturity but not on quarter alignment
        StakedNToken.stakeNToken(
            accounts[0],
            1,
            100e8,
            START_TIME_TREF + SECONDS_IN_QUARTER * 86400,
            START_TIME_TREF + 110,
        )


def test_unstaking_outside_window(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    # Cannot unstake outside the window
    with brownie.reverts("Invalid unstake time"):
        StakedNToken.unstakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER + 7 * SECONDS_IN_DAY + 1
        )

        StakedNToken.unstakeNToken(
            accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER + 8 * SECONDS_IN_DAY
        )


def test_unstaking_with_maturity_in_future_quarter(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + 3 * SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    # Cannot unstake until the quarter
    with brownie.reverts("Invalid unstake time"):
        StakedNToken.unstakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER)

        StakedNToken.unstakeNToken(accounts[0], 1, 100e8, START_TIME_TREF + 2 * SECONDS_IN_QUARTER)


def test_unstaking_insufficient_balance(StakedNToken, accounts):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    with brownie.reverts():
        # More balance than the account has
        StakedNToken.unstakeNToken(accounts[0], 1, 200e8, START_TIME_TREF + SECONDS_IN_QUARTER + 1)

        # Account has no position at all
        StakedNToken.unstakeNToken(accounts[1], 1, 200e8, START_TIME_TREF + SECONDS_IN_QUARTER + 1)


@given(
    windowOffset=strategy("uint32", min_value=0, max_value=7 * SECONDS_IN_DAY),
    # Any reasonable time in a future quarter
    quarterOffset=strategy("uint32", min_value=2, max_value=8),
)
def test_unstaking_at_maturity(StakedNToken, accounts, quarterOffset, windowOffset):
    StakedNToken.stakeNToken(
        accounts[0], 1, 100e8, START_TIME_TREF + SECONDS_IN_QUARTER, START_TIME_TREF + 100
    )

    for i in range(1, quarterOffset):
        StakedNToken.updateAccumulatedNOTEIncentives(1, START_TIME_TREF + i * SECONDS_IN_QUARTER)

    # Unstaking is valid anytime during the 7 day staking window
    blockTime = START_TIME_TREF + quarterOffset * SECONDS_IN_QUARTER + windowOffset
    StakedNToken.unstakeNToken(accounts[0], 1, 100e8, blockTime)
    assert StakedNToken.getNTokenClaim(1, accounts[0].address) == 0
    assert StakedNToken.getNTokenStaker(accounts[0].address, 1).dict()["stakedNTokenBalance"] == 0

    check_invariants(StakedNToken, accounts, blockTime)


@given(initialStake=strategy("uint80"), secondStake=strategy("uint80"))
def test_stake_ntoken(StakedNToken, accounts, initialStake, secondStake):
    blockTime = START_TIME_TREF + 100
    StakedNToken.stakeNToken(
        accounts[0], 1, initialStake, START_TIME_TREF + SECONDS_IN_QUARTER, blockTime
    )
    assert initialStake == StakedNToken.getNTokenClaim(1, accounts[0].address)

    StakedNToken.stakeNToken(
        accounts[1], 1, secondStake, START_TIME_TREF + SECONDS_IN_QUARTER, blockTime
    )

    # Account 0 claim does not change
    assert initialStake == StakedNToken.getNTokenClaim(1, accounts[0].address)
    assert secondStake == StakedNToken.getNTokenClaim(1, accounts[1].address)

    check_invariants(StakedNToken, accounts, blockTime)


@given(
    acct0Stake=strategy("uint80", min_value=100_000e8, max_value=100_000_000e8),
    acct1Stake=strategy("uint80", min_value=0, max_value=100_000_000e8),
    feeAmount=strategy("uint80", min_value=0, max_value=100_000e8),
)
def test_paying_fees_increases_stake(StakedNToken, accounts, acct0Stake, acct1Stake, feeAmount):
    blockTime = START_TIME_TREF + 100
    totalStake = acct0Stake + acct1Stake
    acct0FeeShare = (feeAmount * acct0Stake) / totalStake
    acct1FeeShare = (feeAmount * acct1Stake) / totalStake
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER

    StakedNToken.stakeNToken(accounts[0], 1, acct0Stake, unstakeMaturity, blockTime)
    StakedNToken.stakeNToken(accounts[1], 1, acct1Stake, unstakeMaturity, blockTime)
    assert acct0Stake == StakedNToken.getNTokenClaim(1, accounts[0].address)
    assert acct1Stake == StakedNToken.getNTokenClaim(1, accounts[1].address)

    StakedNToken.payFeeToStakedNToken(1, feeAmount, blockTime)
    assert pytest.approx(acct0Stake + acct0FeeShare, abs=10) == StakedNToken.getNTokenClaim(
        1, accounts[0].address
    )
    assert pytest.approx(acct1Stake + acct1FeeShare, abs=10) == StakedNToken.getNTokenClaim(
        1, accounts[1].address
    )

    # Stake a bit more to ensure additional staking does not have a dilutive effect
    StakedNToken.stakeNToken(accounts[0], 1, 5e8, unstakeMaturity, blockTime)
    StakedNToken.stakeNToken(accounts[2], 1, 100e8, unstakeMaturity, blockTime)
    assert pytest.approx(acct0Stake + acct0FeeShare + 5e8, abs=10) == StakedNToken.getNTokenClaim(
        1, accounts[0].address
    )
    assert pytest.approx(100e8, abs=10) == StakedNToken.getNTokenClaim(1, accounts[2].address)

    check_invariants(StakedNToken, accounts, blockTime)


def test_negative_cash_when_paying_fee(StakedNToken):
    with brownie.reverts():
        StakedNToken.payFeeToStakedNToken(1, -100, START_TIME_TREF + 100)


def test_invalid_values_to_redeem_ntoken(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.changeNTokenSupply(200e8, blockTime)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)

    with brownie.reverts():
        StakedNToken.simulateRedeemNToken(1, -100e8, 100e8, 100e8, blockTime)
        StakedNToken.simulateRedeemNToken(1, 100e8, -100e8, 100e8, blockTime)

    with brownie.reverts("Insufficient nTokens"):
        StakedNToken.simulateRedeemNToken(1, 101e8, 100e8, 100e8, blockTime)

    with brownie.reverts("Insufficient cash raised"):
        StakedNToken.simulateRedeemNToken(1, 50e8, 100e8, 99e8, blockTime)


def test_redeem_ntokens_for_shortfall_to_zero(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.changeNTokenSupply(200e8, blockTime)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)

    # Redeem the stakedNToken down to zero
    StakedNToken.simulateRedeemNToken(1, 100e8, 100e8, 100e8, blockTime)

    stakedSupply = StakedNToken.getStakedNTokenSupply(1).dict()
    assert stakedSupply["totalSupply"] == 100e8
    assert stakedSupply["nTokenBalance"] == 0
    assert 0 == StakedNToken.getNTokenClaim(1, accounts[0].address)

    check_invariants(StakedNToken, accounts, blockTime)


def test_redeem_ntokens_for_shortfall(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    initialNTokenStake = 100e8
    buffer = 50e8
    nTokensToRedeem = initialNTokenStake - buffer
    # Ensure there is sufficient supply
    StakedNToken.changeNTokenSupply(initialNTokenStake * 2, blockTime)

    StakedNToken.stakeNToken(accounts[0], 1, initialNTokenStake, unstakeMaturity, blockTime)

    StakedNToken.simulateRedeemNToken(1, nTokensToRedeem, 100e8, 100e8, blockTime)
    stakedSupply = StakedNToken.getStakedNTokenSupply(1).dict()
    assert stakedSupply["totalSupply"] == initialNTokenStake
    assert stakedSupply["nTokenBalance"] == initialNTokenStake - nTokensToRedeem
    assert (initialNTokenStake - nTokensToRedeem) == StakedNToken.getNTokenClaim(
        1, accounts[0].address
    )

    # Staking more retains no "memory" of the redemption
    StakedNToken.stakeNToken(accounts[0], 1, initialNTokenStake, unstakeMaturity, blockTime)
    StakedNToken.stakeNToken(accounts[1], 1, initialNTokenStake, unstakeMaturity, blockTime)
    assert (2 * initialNTokenStake - nTokensToRedeem) == StakedNToken.getNTokenClaim(
        1, accounts[0].address
    )
    assert initialNTokenStake == StakedNToken.getNTokenClaim(1, accounts[1].address)

    check_invariants(StakedNToken, accounts, blockTime)


def test_transfer_staked_token_matched_maturities(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)

    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)
    StakedNToken.stakeNToken(accounts[1], 1, 100e8, unstakeMaturity, blockTime)

    StakedNToken.transferStakedNToken(
        accounts[0], accounts[1], 1, 50e8, blockTime + 30 * SECONDS_IN_DAY
    )
    check_invariants(StakedNToken, accounts, blockTime + 30 * SECONDS_IN_DAY)
    acct0 = StakedNToken.getNTokenStaker(accounts[0], 1).dict()
    acct1 = StakedNToken.getNTokenStaker(accounts[1], 1).dict()

    assert acct0["stakedNTokenBalance"] == 50e8
    assert acct1["stakedNTokenBalance"] == 150e8
    assert acct0["unstakeMaturity"] == unstakeMaturity
    assert acct1["unstakeMaturity"] == unstakeMaturity
    # Both accounts have accumulated the same amount of NOTE
    assert acct0["accumulatedNOTE"] == acct1["accumulatedNOTE"]


def test_transfer_staked_token_no_maturity(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)
    StakedNToken.transferStakedNToken(
        accounts[0], accounts[1], 1, 50e8, blockTime + 30 * SECONDS_IN_DAY
    )

    check_invariants(StakedNToken, accounts, blockTime + 30 * SECONDS_IN_DAY)
    acct0 = StakedNToken.getNTokenStaker(accounts[0], 1).dict()
    acct1 = StakedNToken.getNTokenStaker(accounts[1], 1).dict()

    assert acct0["stakedNTokenBalance"] == 50e8
    assert acct1["stakedNTokenBalance"] == 50e8
    assert acct0["unstakeMaturity"] == unstakeMaturity
    assert acct1["unstakeMaturity"] == unstakeMaturity
    assert acct1["accumulatedNOTE"] == 0


def test_transfer_staked_token_mismatch_maturities(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)
    StakedNToken.stakeNToken(accounts[1], 1, 100e8, unstakeMaturity + SECONDS_IN_QUARTER, blockTime)

    with brownie.reverts("Maturity mismatch"):
        StakedNToken.transferStakedNToken(
            accounts[0], accounts[1], 1, 50e8, blockTime + 30 * SECONDS_IN_DAY
        )


def test_transfer_staked_token_insufficient_balance(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)

    with brownie.reverts():
        StakedNToken.transferStakedNToken(
            accounts[0], accounts[1], 1, 200e8, blockTime + 30 * SECONDS_IN_DAY
        )


@pytest.mark.only
def test_transfer_staked_token_misatch_but_increase(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    unstakeMaturity = START_TIME_TREF + SECONDS_IN_QUARTER
    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)
    StakedNToken.stakeNToken(accounts[0], 1, 100e8, unstakeMaturity, blockTime)
    StakedNToken.stakeNToken(accounts[1], 1, 100e8, unstakeMaturity + SECONDS_IN_QUARTER, blockTime)

    with brownie.reverts("Maturity mismatch"):
        # Logs a mismatch inside unstake window
        StakedNToken.transferStakedNToken(
            accounts[0], accounts[1], 1, 50e8, blockTime + SECONDS_IN_QUARTER
        )

    # Can transfer outside of unstake window
    blockTime = blockTime + SECONDS_IN_QUARTER + 7 * SECONDS_IN_DAY
    StakedNToken.transferStakedNToken(accounts[0], accounts[1], 1, 50e8, blockTime)
    check_invariants(StakedNToken, accounts, blockTime)

    acct0 = StakedNToken.getNTokenStaker(accounts[0], 1).dict()
    acct1 = StakedNToken.getNTokenStaker(accounts[1], 1).dict()

    assert acct0["stakedNTokenBalance"] == 50e8
    assert acct1["stakedNTokenBalance"] == 150e8
    # Maturities are now aligned at the next unstaking term
    assert acct0["unstakeMaturity"] == unstakeMaturity + SECONDS_IN_QUARTER
    assert acct1["unstakeMaturity"] == unstakeMaturity + SECONDS_IN_QUARTER
    # Acct1 has accumulated more NOTE for staking at a longer term
    assert acct0["accumulatedNOTE"] < acct1["accumulatedNOTE"]


def test_term_weights(StakedNToken, accounts):
    blockTime = START_TIME_TREF + 100
    with brownie.reverts("Invalid rate"):
        StakedNToken.setupIncentives(1, 100_000, 2 ** 32 - 1, [1, 2, 3, 4], blockTime)

    with brownie.reverts("Invalid term weight"):
        StakedNToken.setupIncentives(1, 100_000, 400_000, [1, 2, 3, 4], blockTime)

    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)

    assert StakedNToken.getTermWeights(1, 0) == 10
    assert StakedNToken.getTermWeights(1, 1) == 50
    assert StakedNToken.getTermWeights(1, 2) == 50
    assert StakedNToken.getTermWeights(1, 3) == 90
    check_invariants(StakedNToken, accounts, blockTime)


# def test_update_incentive_emission_rate(StakedNToken, accounts):
# def test_update_term_weights(StakedNToken, accounts):


def test_incentives_simulation_outside_window(StakedNToken, accounts):
    blockTime = START_TIME_TREF + SECONDS_IN_DAY
    StakedNToken.setupIncentives(1, 100_000, 400_000, [10, 50, 50, 90], blockTime)
    StakedNToken.changeNTokenSupply(1000e8, START_TIME_TREF)
    stakeAmount = 100e8

    def unstakeMaturity(x):
        START_TIME_TREF + x * SECONDS_IN_QUARTER

    incentiveAccumulator = None
    activeTerms = []
    stakedSupply = []
    for i in range(0, 4):
        # This increments the base ntoken counter
        StakedNToken.stakeNToken(accounts[i], 1, stakeAmount, unstakeMaturity(i + 1), blockTime)

        incentiveAccumulator = check_invariants(
            StakedNToken, accounts, blockTime, incentiveAccumulator
        )
        blockTime += SECONDS_IN_DAY
        activeTerms.append(StakedNToken.getStakedMaturityIncentivesFromRef(1, START_TIME_TREF))
        stakedSupply.append(StakedNToken.getStakedNTokenSupply(1).dict())

    # assert that longer terms have higher incentives
    # assert that one year will yield the face rate of tokens
    assert False


# def test_incentives_simulation_inside_window(StakedNToken, accounts):
# def test_paying_fees_accumulates_note()
# def test_redeeming_accumulates_note()

"""
simulation:
    actions during quarter:
    stake
    pay fee
    redeem for shortfall
    transfer

    actions during window:
    stake
    redeem for shortfall
    unstake
    transfer

    # make this a separate test
    incentives over a year will equal totalAnnualTermEmission + underlyingEmissionRate
"""
