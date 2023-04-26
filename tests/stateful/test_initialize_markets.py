import math
import logging

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment
from tests.constants import RATE_PRECISION, SECONDS_IN_DAY, SECONDS_IN_QUARTER, SECONDS_IN_YEAR
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
    get_interest_rate_curve,
    get_tref,
    initialize_environment,
    setup_residual_environment,
)
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

LOGGER = logging.getLogger(__name__)
chain = Chain()
INITIAL_CASH_AMOUNT = 100_000e18
INITIAL_CASH_INTERNAL = 100_000e8


@pytest.fixture(scope="module", autouse=False)
def environment(accounts):
    env = TestEnvironment(accounts[0])
    env.enableCurrency("DAI", CurrencyDefaults)

    token = env.token["DAI"]
    token.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    # Set the blocktime to the beginning of the next tRef otherwise the rates will blow up
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def initialize_markets(environment, accounts):
    currencyId = 2
    environment.notional.updateDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])

    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2], [get_interest_rate_curve()] * 2
    )
    environment.notional.updateInitializationParameters(currencyId, [0, 0], [0.5e9, 0.5e9])

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )
    environment.notional.initializeMarkets(currencyId, True)


def get_maturities(index):
    blockTime = chain.time()
    tRef = blockTime - blockTime % SECONDS_IN_QUARTER
    maturity = []
    if index >= 1:
        maturity.append(tRef + SECONDS_IN_QUARTER)

    if index >= 2:
        maturity.append(tRef + 2 * SECONDS_IN_QUARTER)

    if index >= 3:
        maturity.append(tRef + SECONDS_IN_YEAR)

    if index >= 4:
        maturity.append(tRef + 2 * SECONDS_IN_YEAR)

    if index >= 5:
        maturity.append(tRef + 5 * SECONDS_IN_YEAR)

    if index >= 6:
        maturity.append(tRef + 7 * SECONDS_IN_YEAR)

    if index >= 7:
        maturity.append(tRef + 10 * SECONDS_IN_YEAR)

    if index >= 8:
        maturity.append(tRef + 15 * SECONDS_IN_YEAR)

    if index >= 9:
        maturity.append(tRef + 20 * SECONDS_IN_YEAR)

    return maturity


def interpolate_market_rate(a, b, isSixMonth=False):
    shortMaturity = a[1]
    longMaturity = b[1]
    # Uses last implied rate, chain.mine() causes oracle rates to be skewed
    shortRate = a[5]
    longRate = b[5]

    if isSixMonth:
        return math.trunc(
            abs(
                (longRate - shortRate) * SECONDS_IN_QUARTER / (longMaturity - shortMaturity)
                + shortRate
            )
        )
    else:
        return math.trunc(
            abs(
                (longRate - shortRate)
                * (longMaturity + SECONDS_IN_QUARTER - shortMaturity)
                / (longMaturity - shortMaturity)
                + shortRate
            )
        )


def ntoken_asserts(environment, currencyId, isFirstInit, accounts, wasInit=True):
    blockTime = chain.time()
    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (cashBalance, nTokenBalance, lastMintTime) = environment.notional.getAccountBalance(
        currencyId, nTokenAddress
    )

    (cashGroup, _) = environment.notional.getCashGroupAndAssetRate(currencyId)
    (primeRate, _, _, _) = environment.notional.getPrimeFactors(currencyId, blockTime + 1)
    (portfolio, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (depositShares, leverageThresholds) = environment.notional.getDepositParameters(currencyId)
    (_, proportions) = environment.notional.getInitializationParameters(currencyId)
    maturity = get_maturities(cashGroup[0])
    markets = environment.notional.getActiveMarkets(currencyId)
    previousMarkets = environment.notional.getActiveMarketsAtBlockTime(
        currencyId, blockTime - SECONDS_IN_QUARTER
    )

    # These are always true
    assert nTokenBalance == 0
    assert lastMintTime == 0

    # assert that ntoken has liquidity tokens
    assert len(portfolio) == cashGroup[0]  # max market index

    # These values are used to calculate non first init liquidity values
    totalAssetCashInMarkets = sum([m[3] for m in markets])

    for (i, asset) in enumerate(portfolio):
        assert asset[0] == currencyId
        # assert liquidity token is on a valid maturity date
        assert asset[1] == maturity[i]
        # assert liquidity tokens are ordered
        assert asset[2] == 2 + i
        # assert that there is a matching fCash asset
        assert len(list(filter(lambda a: a[1] == maturity[i], ifCashAssets))) == 1

        # assert that liquidity is proportional to deposit shares
        if isFirstInit:
            # Initialize amount is a percentage of the initial cash amount
            assert pytest.approx(asset[3], abs=1) == INITIAL_CASH_INTERNAL * depositShares[i] / int(
                1e8
            )
        elif wasInit:
            # Initialize amount is a percentage of the net cash amount
            assert (
                pytest.approx(asset[3], abs=1) == totalAssetCashInMarkets * depositShares[i] / 1e8
            )

    assert len(ifCashAssets) >= len(portfolio)
    negativeResiduals = []
    for (i, asset) in enumerate(ifCashAssets):
        assert asset[0] == currencyId
        assert asset[2] == 1

        isResidual = asset[1] not in maturity
        if isResidual and asset[3] < 0:
            negativeResiduals.append(asset)
        elif not isResidual:
            # This is generally true, an edge case can be that the nToken has a positive
            # fCash position but highly unlikely
            assert asset[3] < 0

    if len(negativeResiduals) > 0:
        # FV is the notional value discounted at a 0% interest rate
        # this is the maximum withholding we should ever have
        fv = 0
        for r in negativeResiduals:
            fv += r[3]
        assert 0 < cashBalance and cashBalance <= (-fv * 50)
    else:
        assert cashBalance == 0

    for (i, market) in enumerate(markets):
        assert market[1] == maturity[i]
        # all market liquidity is from the perp token
        assert market[4] == portfolio[i][3]

        totalCashUnderlying = (market[3] * primeRate["supplyFactor"]) / Wei(1e36)
        proportion = int(market[2] * RATE_PRECISION / (totalCashUnderlying + market[2]))
        # assert that market proportions are not above leverage thresholds
        assert proportion <= leverageThresholds[i]

        # Ensure that fCash is greater than zero
        assert market[3] > 0

        kinkRate1 = environment.notional.getInterestRateCurve(2)['activeInterestRateCurve'][i][2]
        if previousMarkets[i][6] == 0:
            # This means that the market is initialized for the first time
            assert pytest.approx(proportion, abs=2) == proportions[i]
        elif proportion == leverageThresholds[i]:
            # In this case then the oracle rate is set by governance using Market.getImpliedRate
            pass
        elif i == 0:
            # The 3 month market should have the same implied rate as the old 6 month
            assert market[5] == previousMarkets[1][5]
        elif i == 1:
            # In any other scenario then the market's oracleRate must be in line with
            # the oracle rate provided by the previous markets, this is a special case
            # for the 6 month market
            if len(previousMarkets) >= 3 and previousMarkets[2][6] != 0:
                # In this case we can interpolate between the old 6 month and 1yr
                computedOracleRate = interpolate_market_rate(
                    previousMarkets[1], previousMarkets[2], isSixMonth=True
                )
                assert pytest.approx(market[5], abs=2) == max(computedOracleRate, kinkRate1)
                assert pytest.approx(market[6], abs=2) == max(computedOracleRate, kinkRate1)
            else:
                # In this case then the proportion is set by governance (there is no
                # future rate to interpolate against)
                assert pytest.approx(proportion, abs=2) == proportions[i]
        else:
            # In this scenario the market is interpolated against the previous two rates
            computedOracleRate = interpolate_market_rate(markets[i - 1], previousMarkets[i])
            assert pytest.approx(market[5], abs=2) == max(computedOracleRate, kinkRate1)
            assert pytest.approx(market[6], abs=2) == max(computedOracleRate, kinkRate1)

    nTokenAccount = environment.notional.getNTokenAccount(nTokenAddress)
    assert nTokenAccount["lastInitializedTime"] == blockTime - blockTime % SECONDS_IN_DAY

    check_system_invariants(environment, accounts)


@pytest.mark.only
def test_first_initialization(environment, accounts):
    currencyId = 2
    with brownie.reverts():
        # no parameters are set
        environment.notional.initializeMarkets(currencyId, True)

    environment.notional.updateDepositParameters(currencyId, [0.4e8, 0.6e8], [0.8e9, 0.8e9])
    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2], [get_interest_rate_curve()] * 2
    )
    environment.notional.updateInitializationParameters(currencyId, [0, 0], [0.5e9, 0.5e9])

    with brownie.reverts():
        # no cash deposits
        environment.notional.initializeMarkets(currencyId, True)

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )

    with EventChecker(environment, "Initialize Markets",
        netLiquidity=lambda x: len(x) == 2
    ) as e:
        txn = environment.notional.initializeMarkets(currencyId, True)
        e['txn'] = txn

    ntoken_asserts(environment, currencyId, True, accounts)

def test_settle_and_initialize(environment, accounts):
    initialize_markets(environment, accounts)
    currencyId = 2
    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    # No trading has occured
    with EventChecker(environment, "Initialize Markets") as e:
        txn = environment.notional.initializeMarkets(currencyId, False)
        e['txn'] = txn

    # Ensure that prime settlement rate does get set
    assert 'SetPrimeSettlementRate' in txn.events

    nTokenAddress = environment.nToken[currencyId].address
    decoded = decode_events(environment, txn)
    grouped = group_events(decoded)
    assert len(grouped['nToken Remove Liquidity']) == 1
    assert grouped['nToken Remove Liquidity'][0]['account'] == nTokenAddress
    # Settles the positive and negative fCash assets at the same time
    assert len(grouped['Settle fCash']) == 2
    assert grouped['Settle fCash'][0]['account'] == nTokenAddress
    assert grouped['Settle fCash'][1]['account'] == nTokenAddress
    assert grouped['Settle fCash'][0]['fCash'] + grouped['Settle fCash'][1]['fCash'] == 0
    assert grouped['Settle fCash'][0]['maturity'] == grouped['Settle fCash'][1]['maturity']

    assert len(grouped['Settle Cash']) == 0
    assert len(grouped['nToken Add Liquidity']) == 2

    ntoken_asserts(environment, currencyId, False, accounts)


@pytest.mark.only
def test_settle_and_extend(environment, accounts):
    initialize_markets(environment, accounts)
    currencyId = 2

    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the one year market
    cashGroup[0] = 3
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9]
    )
    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2, 3], [get_interest_rate_curve()] * 3
    )
    environment.notional.updateInitializationParameters(
        currencyId, [0, 0, 0.0], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    txn = environment.notional.initializeMarkets(currencyId, False)
    ntoken_asserts(environment, currencyId, False, accounts)

    nTokenAddress = environment.nToken[currencyId].address
    decoded = decode_events(environment, txn)
    grouped = group_events(decoded)
    assert len(grouped['nToken Remove Liquidity']) == 1
    assert grouped['nToken Remove Liquidity'][0]['account'] == nTokenAddress
    # Settles the positive and negative fCash assets at the same time
    assert len(grouped['Settle fCash']) == 2
    assert grouped['Settle fCash'][0]['account'] == nTokenAddress
    assert grouped['Settle fCash'][1]['account'] == nTokenAddress
    assert grouped['Settle fCash'][0]['fCash'] + grouped['Settle fCash'][1]['fCash'] == 0
    assert grouped['Settle fCash'][0]['maturity'] == grouped['Settle fCash'][1]['maturity']

    assert len(grouped['Settle Cash']) == 0
    assert len(grouped['nToken Add Liquidity']) == 3

    # Test re-initialization the second time
    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    txn = environment.notional.initializeMarkets(currencyId, False)

    nTokenAddress = environment.nToken[currencyId].address
    decoded = decode_events(environment, txn)
    grouped = group_events(decoded)
    assert len(grouped['nToken Remove Liquidity']) == 2
    # Settles the positive and negative fCash assets at the same time
    assert len(grouped['Settle fCash']) == 2
    assert grouped['Settle fCash'][0]['account'] == nTokenAddress
    assert grouped['Settle fCash'][1]['account'] == nTokenAddress
    assert grouped['Settle fCash'][0]['fCash'] + grouped['Settle fCash'][1]['fCash'] == 0
    assert grouped['Settle fCash'][0]['maturity'] == grouped['Settle fCash'][1]['maturity']

    assert len(grouped['Settle Cash']) == 0
    assert len(grouped['nToken Add Liquidity']) == 3

    ntoken_asserts(environment, currencyId, False, accounts)


def test_mint_after_markets_initialized(environment, accounts):
    initialize_markets(environment, accounts)
    currencyId = 2

    marketsBefore = environment.notional.getActiveMarkets(currencyId)
    tokensToMint = environment.notional.calculateNTokensToMint(currencyId, INITIAL_CASH_AMOUNT)
    (
        cashBalanceBefore,
        nTokenBalanceBefore,
        lastMintTimeBefore,
    ) = environment.notional.getAccountBalance(currencyId, accounts[0])

    # Ensure that the clock ticks forward for lastMintTime check
    blockTime = chain.time() + 1
    chain.mine(1, timestamp=blockTime)

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )
    ntoken_asserts(environment, currencyId, False, accounts, wasInit=False)
    # Assert that no assets in portfolio
    assert len(environment.notional.getAccountPortfolio(accounts[0])) == 0

    marketsAfter = environment.notional.getActiveMarkets(currencyId)
    (cashBalanceAfter, nTokenBalanceAfter, _) = environment.notional.getAccountBalance(
        currencyId, accounts[0]
    )

    # assert increase in market liquidity
    assert len(marketsBefore) == len(marketsAfter)
    for (i, m) in enumerate(marketsBefore):
        assert m[4] < marketsAfter[i][4]

    # assert account balances are in line
    assert cashBalanceBefore == cashBalanceAfter
    assert pytest.approx(nTokenBalanceAfter, abs=5) == nTokenBalanceBefore + tokensToMint


def test_redeem_to_zero_fails(environment, accounts):
    initialize_markets(environment, accounts)
    currencyId = 2

    balance = environment.notional.getAccountBalance(2, accounts[0])
    with brownie.reverts("Cannot redeem"):
        environment.notional.nTokenRedeem(
            accounts[0].address, currencyId, balance[1], True, False, {"from": accounts[0]}
        )

    # This can succeed
    environment.notional.nTokenRedeem(
        accounts[0].address, currencyId, balance[1] - 1e8, True, False, {"from": accounts[0]}
    )

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolio, ifCashAssets) = environment.notional.getNTokenPortfolio(nTokenAddress)

    # assert no assets in ntoken
    assert len(portfolio) == 2
    assert len(ifCashAssets) == 2

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )


def test_failing_initialize_time(environment, accounts):
    initialize_markets(environment, accounts)
    currencyId = 2

    # Initializing again immediately will fail
    with brownie.reverts():
        environment.notional.initializeMarkets(currencyId, False)

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    # Cannot mint until markets are initialized
    with brownie.reverts("Requires settlement"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(
                    currencyId,
                    "DepositUnderlyingAndMintNToken",
                    depositActionAmount=INITIAL_CASH_AMOUNT,
                )
            ],
            {"from": accounts[0]},
        )

    with brownie.reverts("Requires settlement"):
        environment.notional.nTokenRedeem(
            accounts[0].address, currencyId, 100e8, True, False, {"from": accounts[0]}
        )

def test_floor_rates_at_kink1(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the one year market
    cashGroup[0] = 3
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9]
    )
    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2, 3], [get_interest_rate_curve()] * 3
    )
    environment.notional.updateInitializationParameters(
        currencyId, [0, 0, 0.0], [0.5e9, 0.5e9, 0.5e9]
    )

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )

    environment.notional.initializeMarkets(2, True)
    # Push the interest rates down on the six month market so it initializes at zero
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 2, "notional": 38_000e8, "minSlippage": 0}],
        depositActionAmount=40_000e18,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[0], [ action ], {"from": accounts[0]})
    assert environment.notional.getActiveMarkets(2)[1][5] / 1e9 < 0.015e9

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))
    environment.notional.initializeMarkets(2, False)
    kinkRate1 = environment.notional.getInterestRateCurve(2)['activeInterestRateCurve'][1][2]
    # new interest rate is floored at kink rate 1
    assert environment.notional.getActiveMarkets(2)[1][5] == kinkRate1

    ntoken_asserts(environment, currencyId, False, accounts)

def test_constant_oracle_rates_across_initialize_time(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the two year markets
    cashGroup[0] = 4
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.2e8, 0.2e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2, 3, 4], [get_interest_rate_curve()] * 4
    )
    environment.notional.updateInitializationParameters(
        currencyId, [0, 0, 0, 0], [0.5e9, 0.5e9, 0.5e9, 0.5e9]
    )

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )

    chain.mine(1, timestamp=(chain.time() + 45 * SECONDS_IN_DAY))
    environment.notional.initializeMarkets(currencyId, True)
    ntoken_asserts(environment, currencyId, True, accounts)
    marketsAfter = environment.notional.getActiveMarkets(currencyId)

    # Check that oracle rates are invariant relative to the two initialization times
    for m in marketsAfter:
        # TODO: this is the interest rate at the specified proportion
        assert pytest.approx(m[5], abs=10) == 0.09375e9
        assert pytest.approx(m[6], abs=10) == 0.09375e9

def test_delayed_second_initialize_markets(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the two year markets
    cashGroup[0] = 4
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.2e8, 0.2e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2, 3, 4], [get_interest_rate_curve()] * 4
    )
    environment.notional.updateInitializationParameters(
        currencyId, [0, 0, 0, 0], [0.5e9, 0.5e9, 0.5e9, 0.5e9]
    )

    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId,
                "DepositUnderlyingAndMintNToken",
                depositActionAmount=INITIAL_CASH_AMOUNT,
            )
        ],
        {"from": accounts[0]},
    )

    environment.notional.initializeMarkets(currencyId, True)
    ntoken_asserts(environment, currencyId, True, accounts)

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER + SECONDS_IN_DAY * 65))
    environment.notional.initializeMarkets(currencyId, False)
    ntoken_asserts(environment, currencyId, False, accounts)


@pytest.mark.skip
def test_delayed_second_initialize_markets_negative_residual(environment, accounts):
    currencyId = 2
    environment = initialize_environment(accounts)
    setup_residual_environment(
        environment, accounts, residualType=1, canSellResiduals=True, marketResiduals=False
    )
    environment.token["DAI"].transfer(accounts[1], 1_000_000e18, {"from": accounts[0]})

    # Trade some more to leave yet another residual in the 6 month and 1 year market
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100_000e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 3, "notional": 100_000e8, "minSlippage": 0},
        ],
        depositActionAmount=200_000e18,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    # There is an idiosyncratic residual in the environment above. We will now try to fast forward
    # and re-initialize the markets with the residual left.
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    ntoken_asserts(environment, currencyId, False, accounts)


@pytest.mark.skip
def test_delayed_second_initialize_markets_positive_residual(accounts):
    currencyId = 2
    environment = initialize_environment(accounts)
    setup_residual_environment(
        environment, accounts, residualType=1, canSellResiduals=True, marketResiduals=False
    )

    # Trade some more to leave yet another residual in the 1 year market
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 10000e8, "maxSlippage": 0}],
        depositActionAmount=11000e18,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})

    # There is an idiosyncratic residual in the environment above. We will now try to fast forward
    # and re-initialize the markets with the residual left.
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    ntoken_asserts(environment, currencyId, False, accounts)
