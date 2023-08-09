import random

import pytest
from brownie import MockAggregator, SimpleStrategyVault
from brownie.convert.datatypes import Wei
from brownie.network import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import (
    PRIME_CASH_VAULT_MATURITY,
    SECONDS_IN_QUARTER,
    START_TIME_TREF,
)

chain = Chain()


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def get_collateral_ratio(vaultConfigValuation, vault, isPrimeCash, secondaryCurrencies, **kwargs):
    vault.setExchangeRate(kwargs.get("exchangeRate", 1.2e18))
    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER

    account = get_vault_account(
        maturity=maturity,
        accountDebtUnderlying=kwargs.get("accountDebtUnderlying", -100_000e8),
        tempCashBalance=kwargs.get("tempCashBalance", 0),
        vaultShares=kwargs.get("accountVaultShares", 100_000e8),
    )

    state = get_vault_state(
        maturity=maturity,
        totalVaultShares=kwargs.get("totalVaultShares", 100_000e8),
    )

    if "netUnderlyingDebtOne" in kwargs or "netUnderlyingDebtTwo" in kwargs:
        netUnderlyingDebtOne = (
            kwargs.get("netUnderlyingDebtOne", -10_000e8) if secondaryCurrencies[0] != 0 else 0
        )
        netUnderlyingDebtTwo = (
            kwargs.get("netUnderlyingDebtTwo", -10_000e8) if secondaryCurrencies[1] != 0 else 0
        )
        chain.mine(1, timedelta=1)
        vaultConfigValuation.updateAccountSecondaryDebt(
            vault, accounts[0], maturity, netUnderlyingDebtOne, netUnderlyingDebtTwo, False
        )

    txn = vaultConfigValuation.calculateHealthFactors(vault, account, state)
    factors = txn.events["HealthFactors"]["h"]
    return factors["collateralRatio"]


def get_secondary_currencies(currencyId, hasSecondaryOne, hasSecondaryTwo):
    remainingCurrencies = [1, 2, 3, 4]
    remainingCurrencies.remove(currencyId)
    if hasSecondaryOne:
        secondaryOne = random.choice(remainingCurrencies)
        remainingCurrencies.remove(secondaryOne)
    else:
        secondaryOne = 0

    if hasSecondaryTwo:
        secondaryTwo = random.choice(remainingCurrencies)
        remainingCurrencies.remove(secondaryTwo)
    else:
        secondaryTwo = 0

    return [secondaryOne, secondaryTwo]


def setup_vault(
    vaultConfigValuation,
    accounts,
    currencyId,
    secondaryCurrencies,
    isPrimeCash,
    enablefCashDiscount,
):
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigValuation.address, currencyId, {"from": accounts[0]}
    )

    flags = set_flags(0, ENABLE_FCASH_DISCOUNT=enablefCashDiscount) if enablefCashDiscount else 0
    vaultConfigValuation.setVaultConfig(
        vault.address,
        get_vault_config(
            currencyId=currencyId, secondaryBorrowCurrencies=secondaryCurrencies, flags=flags
        ),
    )

    if secondaryCurrencies[0] != 0:
        vaultConfigValuation.setMaxBorrowCapacity(vault, secondaryCurrencies[0], 5_000_000e8)

    if secondaryCurrencies[1] != 0:
        vaultConfigValuation.setMaxBorrowCapacity(vault, secondaryCurrencies[1], 5_000_000e8)

    if secondaryCurrencies[0] != 0 or secondaryCurrencies[1] != 0:
        maturity = (
            PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
        )
        netUnderlyingDebtOne = -10_000e8 if secondaryCurrencies[0] != 0 else 0
        netUnderlyingDebtTwo = -10_000e8 if secondaryCurrencies[1] != 0 else 0
        vaultConfigValuation.updateAccountSecondaryDebt(
            vault, accounts[0], maturity, netUnderlyingDebtOne, netUnderlyingDebtTwo, False
        )

    return vault


"""
Valuation Factors:

    - Debt Outstanding:
        - accountDebtUnderlying (PV, not PV, settled to prime cash)
        - secondaryDebt (PV, not PV, settled to prime cash)
        - exchange rates

    - Account Cash Held
        - primary cash
        - secondary cash
        - exchange rates
"""


@given(currencyId=strategy("uint", min_value=1, max_value=4))
def test_cash_value_of_shares(vaultConfigState, accounts, currencyId):
    # Tests that the vault properly converts cash values during valuation
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigState.address, currencyId, {"from": accounts[0]}
    )
    vaultConfigState.setVaultConfig(vault.address, get_vault_config(currencyId=currencyId))
    state = get_vault_state(
        maturity=START_TIME_TREF + SECONDS_IN_QUARTER,
        totalVaultShares=100_000e8,
    )
    vault.setExchangeRate(1.2e18)

    underlyingValue = vaultConfigState.getCashValueOfShare(
        vault.address, accounts[0], state, 100_000e8
    )

    assert underlyingValue == 120_000e8


@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    hasSecondaryOne=strategy("bool"),
    hasSecondaryTwo=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_decreases_with_primary_debt(
    vaultConfigValuation,
    isPrimeCash,
    currencyId,
    hasSecondaryOne,
    hasSecondaryTwo,
    enablefCashDiscount,
):
    secondaryCurrencies = get_secondary_currencies(currencyId, hasSecondaryOne, hasSecondaryTwo)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )

    debt = 0
    decrement = -10_000e8
    lastCollateral = 2 ** 255
    for i in range(0, 10):
        ratio = get_collateral_ratio(
            vaultConfigValuation,
            vault,
            isPrimeCash,
            secondaryCurrencies,
            accountDebtUnderlying=debt,
        )
        debt += decrement
        assert ratio < lastCollateral
        lastCollateral = ratio

@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_decreases_with_secondary_vault_cash(
    vaultConfigValuation, isPrimeCash, currencyId, enablefCashDiscount
):
    secondaryCurrencies = get_secondary_currencies(currencyId, True, True)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )
    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
    vaultConfigValuation.updateAccountSecondaryDebt(
        vault, accounts[0], maturity, -100_000e8, -100_000e8, False
    )

    # Account has 100_000e8 debt in both currencies 1 and 2
    lastCollateral = -1e9
    primeCashOne = 0
    primeCashTwo = 0
    for i in range(0, 10):
        primeCashOneChange = 100e8 if random.randint(0, 1) else 0
        primeCashTwoChange = 100e8 if random.randint(0, 1) else 0
        primeCashOne += primeCashOneChange
        primeCashTwo += primeCashTwoChange
        vaultConfigValuation.setVaultAccountSecondaryCash(
            accounts[0], vault, primeCashOne, primeCashTwo
        )

        ratio = get_collateral_ratio(
            vaultConfigValuation,
            vault,
            isPrimeCash,
            secondaryCurrencies,
            accountDebtUnderlying=-100_000e8,
        )
        if primeCashOneChange != 0 and primeCashTwoChange != 0:
            assert lastCollateral < ratio
        lastCollateral = ratio

@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_decreases_with_secondary_debt(
    vaultConfigValuation, isPrimeCash, currencyId, enablefCashDiscount
):
    secondaryCurrencies = get_secondary_currencies(currencyId, True, True)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )
    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
    vaultConfigValuation.updateAccountSecondaryDebt(
        vault, accounts[0], maturity, -10_000e8, -10_000e8, False
    )

    lastCollateral = -1e9
    for i in range(0, 10):
        netUnderlyingDebtOne = 500e8 if random.randint(0, 1) else 0
        netUnderlyingDebtTwo = 500e8 if random.randint(0, 1) else 0
        ratio = get_collateral_ratio(
            vaultConfigValuation,
            vault,
            isPrimeCash,
            secondaryCurrencies,
            accountDebtUnderlying=-1_000e8,
            # Each iteration reduces the total secondary debt outstanding, collateral
            # ratio should increase as a result
            netUnderlyingDebtOne=netUnderlyingDebtOne,
            netUnderlyingDebtTwo=netUnderlyingDebtTwo,
        )
        if netUnderlyingDebtOne != 0 and netUnderlyingDebtTwo != 0:
            assert lastCollateral < ratio
        lastCollateral = ratio


@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    hasSecondaryOne=strategy("bool"),
    hasSecondaryTwo=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_decrease_with_interest_rates(
    vaultConfigValuation,
    currencyId,
    isPrimeCash,
    hasSecondaryOne,
    hasSecondaryTwo,
    enablefCashDiscount,
):
    secondaryCurrencies = get_secondary_currencies(currencyId, hasSecondaryOne, hasSecondaryTwo)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )

    threeMo = START_TIME_TREF + SECONDS_IN_QUARTER
    lastCollateral = 2 ** 255
    currencies = [currencyId] + list(filter(lambda x: x != 0, secondaryCurrencies))
    for i in range(0, 10):
        # As the interest rates decrease, vault valuations decrease as well
        # because fCash debt becomes less discounted, randomly change the interest rates on any
        # one of the currencies
        modifyCurrency = random.choice(currencies)
        market = list(vaultConfigValuation.getMarket(modifyCurrency, threeMo, threeMo))
        market[5] = market[5] - 1e7
        market[6] = market[6] - 1e7
        vaultConfigValuation.setMarket(modifyCurrency, threeMo, market)

        ratio = get_collateral_ratio(vaultConfigValuation, vault, isPrimeCash, secondaryCurrencies)

        if (isPrimeCash or not enablefCashDiscount) and lastCollateral != 2 ** 255:
            assert pytest.approx(ratio, abs=10) == lastCollateral
        else:
            assert ratio < lastCollateral
        lastCollateral = ratio


@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    hasSecondaryOne=strategy("bool"),
    hasSecondaryTwo=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_increases_with_strategy_token_rate(
    vaultConfigValuation,
    isPrimeCash,
    currencyId,
    hasSecondaryOne,
    hasSecondaryTwo,
    enablefCashDiscount,
):
    secondaryCurrencies = get_secondary_currencies(currencyId, hasSecondaryOne, hasSecondaryTwo)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )

    exchangeRate = 1.2e28
    increment = 0.01e28
    lastCollateral = -1e9
    for i in range(0, 10):
        ratio = get_collateral_ratio(
            vaultConfigValuation, vault, isPrimeCash, secondaryCurrencies, exchangeRate=exchangeRate
        )
        exchangeRate += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    hasSecondaryOne=strategy("bool"),
    hasSecondaryTwo=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_increases_with_vault_shares(
    vaultConfigValuation,
    isPrimeCash,
    currencyId,
    hasSecondaryOne,
    hasSecondaryTwo,
    enablefCashDiscount,
):
    secondaryCurrencies = get_secondary_currencies(currencyId, hasSecondaryOne, hasSecondaryTwo)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )

    vaultShares = 10_000e8
    increment = 1000e8
    lastCollateral = -1e9
    for i in range(0, 10):
        ratio = get_collateral_ratio(
            vaultConfigValuation,
            vault,
            isPrimeCash,
            secondaryCurrencies,
            accountDebtUnderlying=-100e8,
            accountVaultShares=vaultShares,
            exchangeRate=100e18,
        )
        vaultShares += increment
        assert ratio > lastCollateral
        lastCollateral = ratio


@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    hasSecondaryOne=strategy("bool"),
    hasSecondaryTwo=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_increases_with_primary_cash(
    vaultConfigValuation,
    isPrimeCash,
    currencyId,
    hasSecondaryOne,
    hasSecondaryTwo,
    enablefCashDiscount,
):
    secondaryCurrencies = get_secondary_currencies(currencyId, hasSecondaryOne, hasSecondaryTwo)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )

    primeCashHeld = 0
    increment = 10_000e8
    lastCollateral = -1e9
    for i in range(0, 10):
        ratio = get_collateral_ratio(
            vaultConfigValuation,
            vault,
            isPrimeCash,
            secondaryCurrencies,
            tempCashBalance=primeCashHeld,
            exchangeRate=100e18,
        )
        primeCashHeld += increment

        assert ratio > lastCollateral
        lastCollateral = ratio


@given(
    isPrimeCash=strategy("bool"),
    currencyId=strategy("uint", min_value=1, max_value=4),
    enablefCashDiscount=strategy("bool"),
)
def test_collateral_ratio_moves_inverse_with_secondary_exchange_rate(
    vaultConfigValuation, currencyId, isPrimeCash, enablefCashDiscount
):
    secondaryCurrencies = get_secondary_currencies(currencyId, True, True)
    vault = setup_vault(
        vaultConfigValuation,
        accounts,
        currencyId,
        secondaryCurrencies,
        isPrimeCash,
        enablefCashDiscount,
    )

    if secondaryCurrencies[0] == 1:
        # If ETH, must invert the primary borrow currency rate
        secondaryOracleOne = MockAggregator.at(
            vaultConfigValuation.getETHRate(currencyId)["rateOracle"]
        )
    else:
        secondaryOracleOne = MockAggregator.at(
            vaultConfigValuation.getETHRate(secondaryCurrencies[0])["rateOracle"]
        )

    if secondaryCurrencies[1] == 1:
        # If ETH, must invert the primary borrow currency rate
        secondaryOracleTwo = MockAggregator.at(
            vaultConfigValuation.getETHRate(currencyId)["rateOracle"]
        )
    else:
        secondaryOracleTwo = MockAggregator.at(
            vaultConfigValuation.getETHRate(secondaryCurrencies[1])["rateOracle"]
        )

    lastCollateral = -1e9
    for i in range(0, 10):
        # As exchange rates decrease, the debt becomes less in terms of the primary
        # so the collateral ratio goes up
        if secondaryCurrencies[0] == 1:
            secondaryOracleOne.setAnswer(secondaryOracleOne.latestAnswer() * 1.01)
        else:
            secondaryOracleOne.setAnswer(secondaryOracleOne.latestAnswer() * 0.99)

        if secondaryCurrencies[1] == 1:
            secondaryOracleTwo.setAnswer(secondaryOracleTwo.latestAnswer() * 1.01)
        else:
            secondaryOracleTwo.setAnswer(secondaryOracleTwo.latestAnswer() * 0.99)

        ratio = get_collateral_ratio(vaultConfigValuation, vault, isPrimeCash, secondaryCurrencies)
        assert ratio > lastCollateral
        lastCollateral = ratio


@given(
    totalDebt=strategy("int", min_value=-100_000, max_value=-10_000),
    initialRatio=strategy("uint", min_value=0, max_value=30),
    enablefCashDiscount=strategy("bool"),
    isPrimeCash=strategy("bool"),
)
def test_calculate_deleverage_amount(
    vaultConfigValuation, accounts, totalDebt, initialRatio, enablefCashDiscount, isPrimeCash
):
    totalDebt = totalDebt * 1e8
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigValuation.address, 1, {"from": accounts[0]}
    )
    vaultConfigValuation.setVaultConfig(
        vault.address,
        get_vault_config(
            maxDeleverageCollateralRatioBPS=4000,
            minAccountBorrowSize=10_000e8,
            liquidationRate=104,
            flags=set_flags(0, ENABLE_FCASH_DISCOUNT=enablefCashDiscount),
        ),
    )
    vault.setExchangeRate(1e18)
    vaultShares = -totalDebt + initialRatio * -totalDebt / 100
    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(
        maturity=maturity,
        totalDebtUnderlying=totalDebt * 10,
        totalVaultShares=100_000e8,
    )
    account = get_vault_account(
        maturity=maturity, accountDebtUnderlying=totalDebt, vaultShares=vaultShares
    )

    (
        factors,
        maxDeposits,
        vaultSharesToLiquidator,
        _,
    ) = vaultConfigValuation.getVaultAccountHealthFactors(vault.address, account, state)

    if maxDeposits[0] == 0:
        return

    # this is the deposit where all vault shares are purchased
    maxPossibleLiquidatorDeposit = Wei(factors["vaultShareValueUnderlying"] / 1.04)

    assert maxDeposits[0] <= maxPossibleLiquidatorDeposit

    # If maxDeposit == maxPossibleLiquidatorDeposit then all vault shares will be sold and the
    # account is insolvent
    if maxDeposits[0] < maxPossibleLiquidatorDeposit:
        if isPrimeCash:
            # In prime cash, debt is paid down directly
            accountAfter = get_vault_account(
                maturity=maturity,
                accountDebtUnderlying=Wei(totalDebt + maxDeposits[0]),
                vaultShares=vaultShares - vaultSharesToLiquidator[0],
            )
        else:
            # In fCash, deposits are held in cash as collateral
            accountAfter = get_vault_account(
                maturity=maturity,
                accountDebtUnderlying=Wei(totalDebt),
                vaultShares=vaultShares - vaultSharesToLiquidator[0],
                tempCashBalance=vaultConfigValuation.convertFromUnderlying(
                    vaultConfigValuation.buildPrimeRateView(1, chain.time() + 1)[0], maxDeposits[0]
                ),
            )

        # Value of deposits equals the liquidation discount
        assert pytest.approx(vaultSharesToLiquidator[0] / maxDeposits[0], rel=1e-4) == 1.04

        (
            factorsAfter,
            maxDepositsAfter,
            vaultSharesAfter,
            _,
        ) = vaultConfigValuation.getVaultAccountHealthFactors(vault.address, accountAfter, state)

        # Assert that min borrow size is respected
        assert (
            pytest.approx(factorsAfter["totalDebtOutstandingInPrimary"], abs=1) == 0
            or factorsAfter["totalDebtOutstandingInPrimary"] <= 10_000e8
        )
        assert factorsAfter["collateralRatio"] > factors["collateralRatio"]

        if factorsAfter["totalDebtOutstandingInPrimary"] < 0:
            assert pytest.approx(factorsAfter["collateralRatio"], rel=1e-2) == 0.4e9


@given(
    totalDebt=strategy("int", min_value=-100_000, max_value=-30_000),
    initialRatio=strategy("uint", min_value=5, max_value=30),
    enablefCashDiscount=strategy("bool"),
    isPrimeCash=strategy("bool"),
)
def test_calculate_deleverage_amount_with_secondaries(
    vaultConfigValuation, accounts, totalDebt, initialRatio, enablefCashDiscount, isPrimeCash
):
    totalDebt = totalDebt * 1e8
    secondaryCurrencies = [1, 3]
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigValuation.address, 2, {"from": accounts[0]}
    )
    vaultConfigValuation.setVaultConfig(
        vault.address,
        get_vault_config(
            currencyId=2,
            maxDeleverageCollateralRatioBPS=4000,
            minAccountBorrowSize=10_000e8,
            liquidationRate=104,
            flags=set_flags(0, ENABLE_FCASH_DISCOUNT=enablefCashDiscount),
            secondaryBorrowCurrencies=secondaryCurrencies,
            # 8000 in DAI = 80 ETH, 8000 USDC
            minAccountSecondaryBorrow=[80, 8000],
        ),
    )

    vaultConfigValuation.setMaxBorrowCapacity(vault, secondaryCurrencies[0], 5_000_000e8)
    vaultConfigValuation.setMaxBorrowCapacity(vault, secondaryCurrencies[1], 5_000_000e8)
    vault.setExchangeRate(1e18)

    vaultShares = -totalDebt + initialRatio * -totalDebt / 100
    maturity = PRIME_CASH_VAULT_MATURITY if isPrimeCash else START_TIME_TREF + SECONDS_IN_QUARTER
    state = get_vault_state(
        maturity=maturity,
        totalDebtUnderlying=totalDebt * 10,
        totalVaultShares=100_000e8,
    )

    # If ETH, must invert the primary borrow currency rate
    secondaryOracleOne = MockAggregator.at(vaultConfigValuation.getETHRate(2)["rateOracle"])
    oracleRateOne = secondaryOracleOne.latestAnswer()

    secondaryOracleTwo = MockAggregator.at(
        vaultConfigValuation.getETHRate(secondaryCurrencies[1])["rateOracle"]
    )
    oracleRateTwo = secondaryOracleTwo.latestAnswer()

    totalPrimaryDebt = totalDebt * 0.40
    secondaryDebtOne = Wei(totalDebt * 0.30 * oracleRateOne / 1e18)
    secondaryDebtTwo = Wei(totalDebt * 0.30 * oracleRateOne / oracleRateTwo)

    account = get_vault_account(
        maturity=maturity, accountDebtUnderlying=totalPrimaryDebt, vaultShares=vaultShares
    )
    vaultConfigValuation.updateAccountSecondaryDebt(
        vault, accounts[0], maturity, secondaryDebtOne, secondaryDebtTwo, True
    )

    (
        factors,
        maxDeposits,
        vaultSharesToLiquidator,
        er,
    ) = vaultConfigValuation.getVaultAccountHealthFactors(vault.address, account, state)

    if maxDeposits[0] == 0:
        return

    # Assert that vault share transfers are priced appropriately
    assert pytest.approx(vaultSharesToLiquidator[0] / maxDeposits[0], rel=1e-4) == 1.04
    assert (
        pytest.approx(vaultSharesToLiquidator[1] / (maxDeposits[1] * er[0] / er[1]), rel=1e-4)
        == 1.04
    )
    assert (
        pytest.approx(vaultSharesToLiquidator[2] / (maxDeposits[2] * er[0] / er[2]), rel=1e-4)
        == 1.04
    )

    # Each liquidation individually will increase the FC, however, the maxDeposit and vault
    # share amounts may change between liquidations
    liquidationOrder = [1, 2, 3]
    random.shuffle(liquidationOrder)
    ratioBefore = factors["collateralRatio"]
    for c in liquidationOrder:
        if c in secondaryCurrencies:
            if c == secondaryCurrencies[0]:
                account[2] = account[2] - vaultSharesToLiquidator[1]
                depositOne = maxDeposits[1]
                depositTwo = 0
            else:
                account[2] = account[2] - vaultSharesToLiquidator[2]
                depositOne = 0
                depositTwo = maxDeposits[2]

            if isPrimeCash:
                # Assert that min borrow is respected here...
                try:
                    vaultConfigValuation.updateAccountSecondaryDebt(
                        vault, accounts[0], maturity, depositOne, depositTwo, True
                    )
                except Exception:
                    # Sometimes this is flaky....
                    vaultConfigValuation.updateAccountSecondaryDebt(
                        vault, accounts[0], maturity, depositOne, depositTwo, False
                    )
            else:
                # In fCash, cash is held against debt
                vaultConfigValuation.setVaultAccountSecondaryCash(
                    accounts[0], vault, depositOne, depositTwo
                )
        else:
            account[2] = account[2] - vaultSharesToLiquidator[0]
            # If primary currency
            if isPrimeCash:
                # In prime cash, debt is paid down directly
                account[0] = account[0] + maxDeposits[0]
            else:
                # Add cash to temp cash balance
                account[4] = vaultConfigValuation.convertFromUnderlying(
                    vaultConfigValuation.buildPrimeRateView(2, chain.time() + 1)[0], maxDeposits[0]
                )

        (
            factorsAfter,
            maxDeposits,
            vaultSharesToLiquidator,
            _,
        ) = vaultConfigValuation.getVaultAccountHealthFactors(vault.address, account, state)

        # if max deposits is zero, collateral ratio will not increase
        # not fully accurate here due to fcash discounting, will get some drift due to
        # timestamp changes
        if ratioBefore > 0.04e9:
            assert factorsAfter["collateralRatio"] - ratioBefore >= -100

        ratioBefore = factorsAfter["collateralRatio"]

    # At dust amounts collateralRatio should be effectively 0
    if factorsAfter["totalDebtOutstandingInPrimary"] < -0.01e8:
        # Since liquidations are partial, account will not always hit max deleverage ratio
        assert factorsAfter["collateralRatio"] > 0.2e9
        assert factorsAfter["collateralRatio"] <= 0.4e9
