import brownie
import math
import pytest
import eth_abi
from brownie.test import given, strategy
from brownie.convert.datatypes import Wei, HexString
from brownie.network.state import Chain
from fixtures import *
from tests.constants import PRIME_CASH_VAULT_MATURITY
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.helpers import get_balance_trade_action
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()
zeroAddress = HexString(0, type_str="bytes20")


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

@pytest.fixture(autouse=False, scope="module")
def ethDAIOracle(environment, MockAggregator):
    oracleAddress = environment.notional.getRateStorage(2)[0][0]
    oracle = brownie.Contract.from_abi("eth-dai", oracleAddress, MockAggregator.abi)
    return oracle

@pytest.fixture(autouse=False, scope="module")
def multiCurrencyVault(environment, accounts, ethDAIOracle, MultiBorrowStrategyVault):
    vault = MultiBorrowStrategyVault.deploy(
        "multi",
        environment.notional.address,
        2, 1, 0,
        [ethDAIOracle, zeroAddress],
        {"from": accounts[0]}
    )

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
            secondaryBorrowCurrencies=[1, 0],
            minAccountSecondaryBorrow=[1e8, 0],
            maxDeleverageCollateralRatioBPS=2500,
            minAccountBorrowSize=50_000e8,
            excessCashLiquidationBonus=101
        ),
        100_000_000e8,
    )

    environment.notional.updateSecondaryBorrowCapacity(
        vault.address,
        1,
        10_000e8
    )

    return vault

def enter_vault(multiCurrencyVault, environment, account, isPrime):
    maturity = (
        PRIME_CASH_VAULT_MATURITY if isPrime else environment.notional.getActiveMarkets(2)[0][1]
    )

    environment.notional.enterVault(
        account,
        multiCurrencyVault.address,
        25_000e18,
        maturity,
        100_000e8,
        0,
        eth_abi.encode_abi(["uint256[2]"], [[Wei(10e8), 0]]),
        {"from": account}
    )

    return maturity

@given(isPrime=strategy("bool"))
def test_enter_multi_currency_vault(accounts, multiCurrencyVault, environment, isPrime):
    with EventChecker(environment, 'Vault Entry', vaults=[multiCurrencyVault]) as e:
        maturity = enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)
        e['txn'] = brownie.history[-1]

    vaultAccount = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    secondaryDebt = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    vaultState = environment.notional.getVaultState(multiCurrencyVault, maturity)
    vaultSecondaryBorrow = environment.notional.getSecondaryBorrow(multiCurrencyVault, 1, maturity)

    assert vaultAccount['vaultShares'] == vaultState['totalVaultShares']
    assert vaultSecondaryBorrow == secondaryDebt['accountSecondaryDebt'][0]
    assert secondaryDebt['maturity'] == maturity
    assert secondaryDebt['accountSecondaryCashHeld'] == [0, 0]

    if isPrime:
        assert pytest.approx(vaultAccount['accountDebtUnderlying'], abs=1000) == -100_000e8
        assert pytest.approx(secondaryDebt['accountSecondaryDebt'][0], abs=1000) == -10e8
        assert secondaryDebt['accountSecondaryDebt'][1] ==  0
    else:
        assert vaultAccount['accountDebtUnderlying'] == -100_000e8
        assert secondaryDebt['accountSecondaryDebt'] == [-10e8, 0]

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(increasePrimary=strategy("bool"), isPrime=strategy("bool"))
def test_increase_multi_currency_vault_position(accounts, multiCurrencyVault, environment, increasePrimary, isPrime):
    maturity = enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)
    healthBefore = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)['h']

    if increasePrimary:
        # Will result in a proportional borrow
        with EventChecker(environment, 'Vault Entry', vaults=[multiCurrencyVault]) as e:
            txn = environment.notional.enterVault(
                accounts[1],
                multiCurrencyVault.address,
                0,
                maturity,
                1_000e8,
                0,
                eth_abi.encode_abi(["uint256[2]"], [[0, 0]]),
                {"from": accounts[1]}
            )
            e['txn'] = txn
        vaultAccount = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
        secondaryDebt = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
        assert pytest.approx(vaultAccount['accountDebtUnderlying'], abs=10_000) == -101_000e8
        # Some amount of secondary was borrowed automatically by the vault
        assert secondaryDebt['accountSecondaryDebt'][0] < -10e8
    else:
        with EventChecker(environment, 'Vault Entry', vaults=[multiCurrencyVault]) as e:
            txn = environment.notional.enterVault(
                accounts[1],
                multiCurrencyVault.address,
                0,
                maturity,
                0,
                0,
                eth_abi.encode_abi(["uint256[2]"], [[Wei(5e8), 0]]),
                {"from": accounts[1]}
            )
            e['txn'] = txn

        vaultAccount = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
        secondaryDebt = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
        assert pytest.approx(vaultAccount['accountDebtUnderlying'], abs=10_000) == -100_000e8
        assert pytest.approx(secondaryDebt['accountSecondaryDebt'][0], abs=10_000) == -15e8
    
    healthAfter = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)['h']
    assert healthAfter['collateralRatio'] < healthBefore['collateralRatio']

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(exitType=strategy("uint8", min_value=0, max_value=2), isPrime=strategy("bool"))
def test_vault_exit_types(accounts, multiCurrencyVault, environment, exitType, isPrime):
    maturity = enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)
    chain.mine(timedelta=65)

    daiBalanceBefore = environment.token['DAI'].balanceOf(accounts[1])
    ethBalanceBefore = accounts[1].balance()

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtBefore = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    vaultSecondaryDebtBefore = environment.notional.getSecondaryBorrow(multiCurrencyVault, 1, maturity)

    if exitType == 0:
        # Exit Primary
        vaultSharesExit = 1_000e8
        daiRepaid = 1_000e8
        ethRepaid = 0
        daiTraded = 0
    elif exitType == 1:
        # Exit Secondary
        vaultSharesExit = 1_000e8
        daiRepaid = 0
        ethRepaid = Wei(1e8)
        daiTraded = Wei(500e18)
    elif exitType == 2:
        # Exit Proportional
        vaultSharesExit = 1_000e8
        daiRepaid = 999e8
        ethRepaid = Wei(0.075e8)
        daiTraded = Wei(0)

    poolClaims = multiCurrencyVault.getPoolClaims(vaultSharesExit)

    with EventChecker(environment, 'Vault Exit', vaults=[multiCurrencyVault]) as e:
        txn = environment.notional.exitVault(
            accounts[1],
            multiCurrencyVault,
            accounts[1],
            vaultSharesExit,
            daiRepaid,
            0,
            eth_abi.encode_abi(['uint256[2]','int256[3]'], [[ethRepaid, 0], [daiTraded, 0, 0]]),
            {"from": accounts[1]}
        )
        e['txn'] = txn

    # decoded = decode_events(environment, txn, vaults=[multiCurrencyVault])
    # grouped = group_events(decoded)
    
    # assert len(grouped['Vault Exit']) == 1
    # if exitType == 0:
    #     if isPrime:
    #         assert len(grouped['Vault Redeem']) == 0
    #     else:
    #         assert len(grouped['Vault Redeem']) == 1
    
    #     assert len(grouped['Vault Secondary Debt']) == 0
    # elif exitType == 1:
    #     assert len(grouped['Vault Redeem']) == 1
    #     assert len(grouped['Vault Secondary Debt']) == 1
    # else:
    #     assert len(grouped['Vault Redeem']) == 1
    #     assert len(grouped['Vault Secondary Debt']) == 1

    daiBalanceAfter = environment.token['DAI'].balanceOf(accounts[1])
    ethBalanceAfter = accounts[1].balance()

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    vaultSecondaryDebtAfter = environment.notional.getSecondaryBorrow(multiCurrencyVault, 1, maturity)

    # Check that debt figures are updated
    assert pytest.approx(vaultAccountAfter['accountDebtUnderlying'], abs=10_000) == vaultAccountBefore['accountDebtUnderlying'] + daiRepaid
    assert pytest.approx(accountDebtAfter['accountSecondaryDebt'][0], abs=10_000) == accountDebtBefore['accountSecondaryDebt'][0] + ethRepaid
    assert pytest.approx(vaultSecondaryDebtAfter, abs=10_000) == vaultSecondaryDebtBefore + ethRepaid

    # Check that vault shares are updated
    assert vaultAccountAfter['vaultShares'] == vaultAccountBefore['vaultShares'] - vaultSharesExit
    # Account can exit multiple times
    # assert vaultAccountAfter['lastUpdateBlockTime'] == vaultAccountBefore['lastUpdateBlockTime']

    netDaiTransfer = daiBalanceAfter - daiBalanceBefore
    netETHTransfer = ethBalanceAfter - ethBalanceBefore

    if daiRepaid > 0:
        # This value represents the discount for repaying the debt
        assert daiRepaid * 1e10 - (poolClaims[0] - netDaiTransfer - daiTraded) >= -0.02e18
        assert daiRepaid * 1e10 - (poolClaims[0] - netDaiTransfer - daiTraded) <= 50e18
    else:
        assert pytest.approx(netDaiTransfer, rel=1e-5) == poolClaims[0] - daiTraded

    if ethRepaid > 0:
        # This value represents the discount for repaying the debt
        assert ethRepaid * 1e10 - (poolClaims[1] - netETHTransfer + daiTraded / 100) >= -0.02e18
        assert ethRepaid * 1e10 - (poolClaims[1] - netETHTransfer + daiTraded / 100) <= 0.05e18
    else:
        assert pytest.approx(netETHTransfer, rel=1e-5) == poolClaims[1] + daiTraded / 100

    check_system_invariants(environment, accounts, [multiCurrencyVault])

def test_vault_exit_at_zero_interest(accounts, multiCurrencyVault, environment):
    maturity = enter_vault(multiCurrencyVault, environment, accounts[1], False)
    chain.mine(timedelta=65)

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)

    # Reduce liquidity in ETH so lending fails on exit
    environment.notional.nTokenRedeem(
        accounts[0], 1, 44_500e8, True, True, {"from": accounts[0]}
    )
    (amountAsset, _, _, _) = environment.notional.getDepositFromfCashLend(
        1, 9e8, maturity, 0, chain.time()
    )
    assert amountAsset == 0

    accounts[0].transfer(multiCurrencyVault, 1e18)
    with EventChecker(environment, 'Vault Exit', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.exitVault(
            accounts[1],
            multiCurrencyVault,
            accounts[1],
            vaultAccountBefore['vaultShares'],
            -vaultAccountBefore['accountDebtUnderlying'],
            0,
            eth_abi.encode_abi(['uint256[2]','int256[3]'], [[Wei(10e8), 0], [0, 0, 0]]),
            {"from": accounts[1]}
        )

    # decoded = decode_events(environment, txn, vaults=[multiCurrencyVault])
    # grouped = group_events(decoded)
    # assert len(grouped['Vault Exit']) == 1
    # assert len(grouped['Vault Redeem']) == 1
    # assert len(grouped['Vault Secondary Debt']) == 1
    # assert len(grouped['Vault Exit [Lend at Zero]']) == 1

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(rollToPrime=strategy("bool"), isPrime=strategy("bool"))
def test_roll_position(accounts, multiCurrencyVault, environment, isPrime, rollToPrime):
    oldMaturity = enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)
    chain.mine(1, timedelta=65)

    if rollToPrime and isPrime:
        # Roll to 3 mo
        maturity = environment.notional.getActiveMarkets(1)[0][1]
    elif rollToPrime:
        # Roll from 3 mo to prime
        maturity = PRIME_CASH_VAULT_MATURITY
    else:
        # Roll from 3 mo to 6 mo
        maturity = environment.notional.getActiveMarkets(1)[1][1]

    with brownie.reverts("Insufficient Secondary Borrow"):
        environment.notional.rollVaultPosition.call(
            accounts[1],
            multiCurrencyVault,
            105_000e8,
            maturity,
            10_000e18, 0, 0,
            eth_abi.encode_abi(['uint256[2]'], [[Wei(1e8), 0]]),
            {"from": accounts[1]}
        )

    with EventChecker(environment, 'Vault Roll', vaults=[multiCurrencyVault]) as e:
        txn = environment.notional.rollVaultPosition(
            accounts[1],
            multiCurrencyVault,
            105_000e8,
            maturity,
            10_000e18, 0, 0,
            eth_abi.encode_abi(['uint256[2]'], [[Wei(11e8), 0]]),
            {"from": accounts[1]}
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)

    assert vaultAccountAfter['maturity'] == maturity
    assert accountDebtAfter['maturity'] == maturity
    assert vaultAccountAfter['lastUpdateBlockTime'] == txn.timestamp
    assert pytest.approx(vaultAccountAfter['accountDebtUnderlying'], abs=10_000) == -105_000e8
    assert pytest.approx(accountDebtAfter['accountSecondaryDebt'][0], abs=10_000) == -11e8

    # Check that the account is healthy
    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert health['collateralRatio'] > 0.2e9

    # Old maturity debt is cleared
    assert environment.notional.getSecondaryBorrow(multiCurrencyVault, 1, oldMaturity) == 0

    check_system_invariants(environment, accounts, [multiCurrencyVault])

def test_settle(accounts, multiCurrencyVault, environment):
    enter_vault(multiCurrencyVault, environment, accounts[1], False)
    maturity = environment.notional.getActiveMarkets(1)[0][1]
    chain.mine(1, timestamp=maturity)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)

    with brownie.reverts(dev_revert_msg="dev: unauthorized"):
        environment.notional.settleSecondaryBorrowForAccount(multiCurrencyVault, accounts[0])

    with EventChecker(environment, 'Vault Settle', vaults=[multiCurrencyVault]) as e:
        txn = environment.notional.settleVaultAccount(
            accounts[1],
            multiCurrencyVault,
            {"from": accounts[1]}
        )
        e['txn'] = txn
    # decoded = decode_events(environment, txn, vaults=[multiCurrencyVault])
    # grouped = group_events(decoded)
    # assert len(grouped['Vault Settle']) == 1
    # assert len(grouped['Vault Secondary Debt']) == 1
    # assert len(grouped['Settle Cash']) == 2
    # assert len(grouped['Settle fCash']) == 2
    # assert grouped['Vault Secondary Debt'][0]['groupType'] == 'Vault Secondary Settle'

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)

    # Account figures have been transferred
    assert vaultAccountAfter['maturity'] == PRIME_CASH_VAULT_MATURITY
    assert vaultAccountAfter['vaultShares'] == vaultAccountBefore['vaultShares']
    assert accountDebtAfter['maturity'] == PRIME_CASH_VAULT_MATURITY
    assert vaultAccountAfter['lastUpdateBlockTime'] == txn.timestamp
    assert pytest.approx(vaultAccountAfter['accountDebtUnderlying'], abs=10_000) == -100_000e8
    assert pytest.approx(accountDebtAfter['accountSecondaryDebt'][0], abs=10_000) == -10e8

    # We don't do a collateral check in this case but assert that the account is healthy
    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert health['collateralRatio'] > 0.2e9

    # Matured debt is cleared
    assert environment.notional.getSecondaryBorrow(multiCurrencyVault, 1, maturity) == 0
    assert pytest.approx(
        environment.notional.getSecondaryBorrow(multiCurrencyVault, 1, PRIME_CASH_VAULT_MATURITY),
        abs=10_000
    ) == -10e8

    check_system_invariants(environment, accounts, [multiCurrencyVault])

# Liquidation Tests
@given(isPrime=strategy("bool"))
def test_oracle_price_affects_debt_value(accounts, multiCurrencyVault, environment, isPrime, ethDAIOracle):
    enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)

    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert pytest.approx(health['netDebtOutstanding'][0], abs=10_000) == -100_000e8
    assert pytest.approx(health['netDebtOutstanding'][1], abs=10_000) == -10e8
    assert pytest.approx(health['totalDebtOutstandingInPrimary'], abs=10_000) == -100_000e8 - 10e8 * 100

    ethDAIOracle.setAnswer(0.02e18, {"from": accounts[0]})

    (health, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert pytest.approx(health['netDebtOutstanding'][0], abs=10_000) == -100_000e8
    assert pytest.approx(health['netDebtOutstanding'][1], abs=10_000) == -10e8
    assert pytest.approx(health['totalDebtOutstandingInPrimary'], abs=10_000) == -100_000e8 - 5e8 * 100

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(isPrime=strategy("bool"))
def test_claims_affect_vault_share_value(accounts, multiCurrencyVault, environment, isPrime):
    enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)

    (healthOne, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert pytest.approx(healthOne['netDebtOutstanding'][0], abs=3) == -100_000e8
    assert pytest.approx(healthOne['netDebtOutstanding'][1], abs=3) == -10e8
    assert pytest.approx(healthOne['netDebtOutstanding'][2], abs=3) == 0
    assert pytest.approx(healthOne['totalDebtOutstandingInPrimary'], abs=150) == -100_000e8 - 10e8 * 100

    multiCurrencyVault.approveTransfer(environment.token['DAI'])
    environment.token['DAI'].transferFrom(multiCurrencyVault, accounts[0], 10_000e18)

    (healthTwo, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert healthTwo['vaultShareValueUnderlying'] == healthOne['vaultShareValueUnderlying'] - 10_000e8
    # Total debt should stay approx the same, may increase due to prime
    assert pytest.approx(healthTwo['totalDebtOutstandingInPrimary'], abs=5_000) == healthOne['totalDebtOutstandingInPrimary']

    accounts[0].transfer(multiCurrencyVault, 100e18)

    (healthFinal, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    # Total debt should stay approx the same, may increase due to prime
    assert pytest.approx(healthFinal['totalDebtOutstandingInPrimary'], abs=5_000) == healthTwo['totalDebtOutstandingInPrimary']
    assert pytest.approx(healthOne['vaultShareValueUnderlying']) == healthFinal['vaultShareValueUnderlying']

    check_system_invariants(environment, accounts, [multiCurrencyVault])


def deleveraged_account(accounts, multiCurrencyVault, environment, isPrime, currencyIndex, ethDAIOracle):
    enter_vault(multiCurrencyVault, environment, accounts[1], isPrime)

    if isPrime:
        ethDAIOracle.setAnswer(0.0004e18, {"from": accounts[0]})
    else:
        ethDAIOracle.setAnswer(0.0011e18, {"from": accounts[0]})
    (healthBefore, maxDeposit, vaultShares) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)

    with EventChecker(environment, 'Vault Deleverage [Prime]' if isPrime else 'Vault Deleverage [fCash]', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.deleverageAccount(
            accounts[1],
            multiCurrencyVault,
            accounts[2],
            currencyIndex,
            maxDeposit[currencyIndex],
            {"from": accounts[2], "value": maxDeposit[1] * 1e10 if currencyIndex == 1 else 0}
        )


    return (vaultAccountBefore, healthBefore, maxDeposit, vaultShares)

@given(isPrime=strategy("bool"), currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_deleverage_secondary(accounts, multiCurrencyVault, environment, isPrime, currencyIndex, ethDAIOracle):
    (vaultAccountBefore, healthBefore, maxDeposit, vaultShares) = deleveraged_account(
        accounts, multiCurrencyVault, environment, isPrime, currencyIndex, ethDAIOracle
    )

    (_, secondaryDebt, secondaryCash) = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)

    if isPrime:
        if currencyIndex == 0:
            assert pytest.approx(vaultAccountBefore['accountDebtUnderlying'] + maxDeposit[0], abs=5_000) == vaultAccount['accountDebtUnderlying']
        else:
            assert pytest.approx(-10e8 + maxDeposit[1], abs=5_000) == secondaryDebt[0]
    else:
        assert secondaryDebt == (-10e8, 0)

        if currencyIndex == 0:
            assert pytest.approx(
                environment.notional.convertCashBalanceToExternal(2, vaultAccount['tempCashBalance'], True) / 1e10,
                abs=100
            ) == maxDeposit[0]
            assert secondaryCash == (0, 0)
        else:
            assert pytest.approx(
                environment.notional.convertCashBalanceToExternal(1, secondaryCash[0], True) / 1e10,
                abs=100
            ) == maxDeposit[1]
            assert vaultAccount['tempCashBalance'] == 0

    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)

    # Check that the liquidator can exit their shares
    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], multiCurrencyVault)
    assert liquidatorAccount['vaultShares'] == vaultShares[currencyIndex]

    with EventChecker(environment, 'Vault Exit', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.exitVault(
            accounts[2],
            multiCurrencyVault,
            accounts[2],
            liquidatorAccount["vaultShares"],
            0, 0, eth_abi.encode(["uint256[2]", "int256[3]"], [[0, 0], [0, 0, 0]]),
            {"from": accounts[2]},
        )

    assert healthBefore['collateralRatio'] < healthAfter['collateralRatio']

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidator_can_liquidate_cash(accounts, multiCurrencyVault, environment, ethDAIOracle, currencyIndex):
    deleveraged_account(
        accounts, multiCurrencyVault, environment, False, currencyIndex, ethDAIOracle
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)

    if currencyIndex == 0:
        depositAmount = -vaultAccountBefore["accountDebtUnderlying"] * 1e10
        lendAmount = -vaultAccountBefore["accountDebtUnderlying"]
        purchaseAmount =  lendAmount
    else:
        depositAmount = 10e18
        lendAmount = 10e8
        purchaseAmount =  lendAmount


    with brownie.reverts("Insufficient free collateral"):
        environment.notional.liquidateVaultCashBalance(
            accounts[1],
            multiCurrencyVault,
            accounts[2],
            currencyIndex,
            purchaseAmount,
            {"from": accounts[2]},
        )

    action = get_balance_trade_action(
        2 if currencyIndex == 0 else 1,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Lend",
                "marketIndex": 1,
                "notional": lendAmount,
                "minSlippage": 0,
            }
        ],
        depositActionAmount=depositAmount,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[2],
        [action],
        {"from": accounts[2], "value": depositAmount if currencyIndex == 1 else 0},
    )

    with EventChecker(environment, 'Vault Liquidate Cash', vaults=[multiCurrencyVault]) as e:
        txn = environment.notional.liquidateVaultCashBalance(
            accounts[1],
            multiCurrencyVault,
            accounts[2],
            currencyIndex,
            purchaseAmount,
            {"from": accounts[2]},
        )
        e['txn'] = txn
    
    if currencyIndex == 0:
        vaultAccount = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
        assert vaultAccount['tempCashBalance'] == 0
        assert vaultAccountBefore['accountDebtUnderlying'] < vaultAccount['accountDebtUnderlying']
    elif currencyIndex == 1:
        (_, secondaryDebt, secondaryCash) = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)

        # Some residual prime cash remaining as a result of discounting
        assert environment.notional.convertCashBalanceToExternal(1, secondaryCash[0], True) < 0.25e18
        assert secondaryCash[1] == 0
        assert secondaryDebt == (0, 0)

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidator_can_liquidate_second_time(accounts, multiCurrencyVault, environment, currencyIndex, ethDAIOracle):
    deleveraged_account(
        accounts, multiCurrencyVault, environment, False, 0, ethDAIOracle
    )

    # Drop price again and liquidate
    ethDAIOracle.setAnswer(0.0005e18, {"from": accounts[0]})
    (healthBefore, maxDeposit, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtBefore = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)

    with EventChecker(environment, 'Vault Deleverage [fCash]', vaults=[multiCurrencyVault]) as e:
        txn = environment.notional.deleverageAccount(
            accounts[1],
            multiCurrencyVault,
            accounts[2],
            currencyIndex,
            maxDeposit[currencyIndex],
            {"from": accounts[2], "value": maxDeposit[1] * 1e10 if currencyIndex == 1 else 0}
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert healthAfter['collateralRatio'] > healthBefore['collateralRatio']

    if currencyIndex == 0:
        assert vaultAccountAfter['tempCashBalance'] > vaultAccountBefore['tempCashBalance']
    else:
        assert accountDebtAfter['accountSecondaryCashHeld'][0] > accountDebtBefore['accountSecondaryCashHeld'][0]

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidated_can_enter(accounts, multiCurrencyVault, environment, currencyIndex, ethDAIOracle):
    deleveraged_account(
        accounts, multiCurrencyVault, environment, False, currencyIndex, ethDAIOracle
    )

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtBefore = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    poolBalancesBefore = multiCurrencyVault.getPoolBalances()

    with EventChecker(environment, 'Vault Entry', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.enterVault(
            accounts[1],
            multiCurrencyVault,
            10_000e18,
            vaultAccountBefore["maturity"],
            10_000e8,
            0,
            eth_abi.encode_abi(["uint256[2]"], [[Wei(3e8), 0]]),
            { "from": accounts[1] },
        )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    poolBalancesAfter = multiCurrencyVault.getPoolBalances()

    assert vaultAccountAfter['tempCashBalance'] == 0
    assert vaultAccountAfter['accountDebtUnderlying'] == -110_000e8
    assert accountDebtAfter['accountSecondaryCashHeld'] == (0, 0)

    assert pytest.approx(poolBalancesAfter[1] - poolBalancesBefore[1], abs=0.5e18) == 3e18 + environment.notional.convertCashBalanceToExternal(1, accountDebtBefore['accountSecondaryCashHeld'][0], True)

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidated_can_exit(accounts, multiCurrencyVault, environment, currencyIndex, ethDAIOracle):
    deleveraged_account(
        accounts, multiCurrencyVault, environment, False, currencyIndex, ethDAIOracle
    )
    chain.mine(1, timedelta=75)

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)

    accounts[1].transfer(multiCurrencyVault, 4e18)
    with EventChecker(environment, 'Vault Exit', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.exitVault(
            accounts[1],
            multiCurrencyVault,
            accounts[1],
            vaultAccountBefore["vaultShares"],
            -vaultAccountBefore["accountDebtUnderlying"],
            0,
            eth_abi.encode_abi(['uint256[2]','int256[3]'], [[Wei(10e8), 0], [0, 0, 0]]),
            {"from": accounts[1]},
        )

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    assert vaultAccountAfter['maturity'] == 0
    assert vaultAccountAfter['accountDebtUnderlying'] == 0
    assert accountDebtAfter == (0, (0, 0), (0, 0))

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidated_can_roll(accounts, multiCurrencyVault, environment, currencyIndex, ethDAIOracle):
    deleveraged_account(
        accounts, multiCurrencyVault, environment, False, currencyIndex, ethDAIOracle
    )

    poolBalancesBefore = multiCurrencyVault.getPoolBalances()

    with EventChecker(environment, 'Vault Roll', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.rollVaultPosition(
            accounts[1],
            multiCurrencyVault,
            100_000e8,
            PRIME_CASH_VAULT_MATURITY,
            0, 0, 0, eth_abi.encode_abi(['uint256[2]'], [[Wei(3e8) if currencyIndex == 1 else Wei(10e8), 0]]),
            {"from": accounts[1]},
        )
    poolBalancesAfter = multiCurrencyVault.getPoolBalances()

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    assert vaultAccountAfter["tempCashBalance"] == 0

    if currencyIndex == 1:
        # Most of the cash is used to repay the existing debt
        assert pytest.approx(poolBalancesAfter[1] - poolBalancesBefore[1], abs=0.5e18) == 3e18
        assert accountDebtAfter == (PRIME_CASH_VAULT_MATURITY, (-3e8 - 1, 0), (0, 0))
    else:
        assert accountDebtAfter == (PRIME_CASH_VAULT_MATURITY, (-10e8 - 1, 0), (0, 0))
        # Most of the borrow is used to repay the existing debt
        assert pytest.approx(poolBalancesAfter[1] - poolBalancesBefore[1], abs=0.5e18) == 0

    check_system_invariants(environment, accounts, [multiCurrencyVault])

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidated_can_settle(accounts, multiCurrencyVault, environment, currencyIndex, ethDAIOracle):
    deleveraged_account(
        accounts, multiCurrencyVault, environment, False, currencyIndex, ethDAIOracle
    )

    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtBefore = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)

    chain.mine(1, timestamp=vaultAccountBefore["maturity"])
    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)

    with EventChecker(environment, 'Vault Settle', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.settleVaultAccount(accounts[1], multiCurrencyVault)

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    accountDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)

    primaryCash = (
        environment.notional.convertCashBalanceToExternal(2, vaultAccountBefore["tempCashBalance"], True)
        / 1e10
    )
    assert pytest.approx(vaultAccountAfter["accountDebtUnderlying"], abs=500) == (
        vaultAccountBefore["accountDebtUnderlying"] + primaryCash
    )
    assert vaultAccountAfter["tempCashBalance"] == 0

    secondaryCash = (
        environment.notional.convertCashBalanceToExternal(1, accountDebtBefore["accountSecondaryCashHeld"][0], True)
        / 1e10
    )
    assert pytest.approx(accountDebtAfter["accountSecondaryDebt"][0], abs=500) == (
        accountDebtBefore["accountSecondaryDebt"][0] + secondaryCash
    )

    check_system_invariants(environment, accounts, [multiCurrencyVault])


def test_borrow_secondary_currency_fails_over_max_capacity(environment, accounts, multiCurrencyVault):
    environment.notional.updateSecondaryBorrowCapacity(multiCurrencyVault.address, 1, 5e8)
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    assert environment.notional.getBorrowCapacity(multiCurrencyVault.address, 1) == (0, 0, 5e8)

    with brownie.reverts("Max Capacity"):
        environment.notional.enterVault(
            accounts[1],
            multiCurrencyVault,
            10_000e18,
            maturity,
            100_000e8,
            0,
            eth_abi.encode_abi(["uint256[2]"], [[Wei(6e8), 0]]),
            { "from": accounts[1] },
        )

@given(currencyIndex=strategy("uint8", min_value=0, max_value=1))
def test_liquidate_cross_currency_cash(
    environment, accounts, ethDAIOracle, multiCurrencyVault, currencyIndex
):
    enter_vault(multiCurrencyVault, environment, accounts[1], False)

    ethDAIOracle.setAnswer(0.001e18, {"from": accounts[0]})
    multiCurrencyVault.approveTransfer(environment.token['DAI'], {'from': accounts[0]})
    environment.token['DAI'].transferFrom(multiCurrencyVault, accounts[0], 5_000e18, {"from": accounts[0]}) 

    # Setup some prime borrowing
    environment.notional.enablePrimeBorrow(True, {"from": accounts[0]})
    environment.notional.withdraw(1, 10_000e8, True, {"from": accounts[0]})
    environment.notional.withdraw(2, 5_000_000e8, True, {"from": accounts[0]})

    (_, maxDeposit, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)

    environment.notional.deleverageAccount(
        accounts[1],
        multiCurrencyVault,
        accounts[2],
        currencyIndex,
        maxDeposit[currencyIndex],
        {"from": accounts[2], "value": maxDeposit[1] * 1e10 if currencyIndex == 1 else 0}
    )

    chain.mine(1, timedelta=86400 * 30)
    accountBefore =environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    secondaryDebtBefore = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    (healthBefore, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert healthBefore['netDebtOutstanding'][currencyIndex] > 0

    with brownie.reverts():
        # Cannot specify incorrect cash and debt indexes
        environment.notional.liquidateExcessVaultCash(
            accounts[1], multiCurrencyVault, accounts[0], 1 - currencyIndex, currencyIndex, 1e8, {'from': accounts[0], 'value': 1e18}
        )

    with EventChecker(environment, 'Vault Liquidate Excess Cash', vaults=[multiCurrencyVault]) as e:
        e['txn'] = environment.notional.liquidateExcessVaultCash(
            accounts[1], multiCurrencyVault, accounts[0], currencyIndex, 1 - currencyIndex, 1e8, {'from': accounts[0], 'value': 1e18 if currencyIndex == 0 else 0}
        )

    accountAfter = environment.notional.getVaultAccount(accounts[1], multiCurrencyVault)
    secondaryDebtAfter = environment.notional.getVaultAccountSecondaryDebt(accounts[1], multiCurrencyVault)
    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], multiCurrencyVault)
    assert healthBefore['netDebtOutstanding'][currencyIndex] > healthAfter['netDebtOutstanding'][currencyIndex]
    assert healthAfter['netDebtOutstanding'][currencyIndex] > 0

    netDAIUnderlying = environment.notional.convertCashBalanceToExternal(2, accountAfter['tempCashBalance'] - accountBefore['tempCashBalance'], True)
    netETHUnderlying = environment.notional.convertCashBalanceToExternal(1, secondaryDebtAfter[2][0] - secondaryDebtBefore[2][0], True)

    if currencyIndex == 0:
        # Account is buying ETH at a higher price
        assert netETHUnderlying > 0
        assert netDAIUnderlying < 0
        assert pytest.approx(abs(netDAIUnderlying / netETHUnderlying), abs=0.25) == 1010
    else:
        # Account is selling ETH at a lower price
        assert netETHUnderlying < 0
        assert netDAIUnderlying > 0
        assert pytest.approx(abs(netDAIUnderlying / netETHUnderlying), abs=0.25) == 990

    check_system_invariants(environment, accounts, [multiCurrencyVault])


def test_enforce_min_borrow_on_liquidation(accounts, MultiBorrowStrategyVault, environment, ethDAIOracle):
    vault = MultiBorrowStrategyVault.deploy(
        "multi",
        environment.notional.address,
        2, 1, 3,
        [ethDAIOracle, ethDAIOracle],
        {"from": accounts[0]}
    )

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
            secondaryBorrowCurrencies=[1, 3],
            minAccountSecondaryBorrow=[1e8, 1e8],
            maxDeleverageCollateralRatioBPS=2500,
            minAccountBorrowSize=50_000e8,
            excessCashLiquidationBonus=101
        ),
        100_000_000e8,
    )

    environment.notional.updateSecondaryBorrowCapacity(
        vault.address,
        1,
        10_000e8
    )

    environment.notional.updateSecondaryBorrowCapacity(
        vault.address,
        3,
        10_000e8
    )

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        25_000e18,
        PRIME_CASH_VAULT_MATURITY,
        100_000e8,
        0,
        eth_abi.encode_abi(["uint256[2]"], [[Wei(10e8), Wei(100e8)]]),
        {"from": accounts[1]}
    )
    ethDAIOracle.setAnswer(0.0004e18, {"from": accounts[0]})

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
            secondaryBorrowCurrencies=[1, 3],
            minAccountSecondaryBorrow=[5e8, 200e8],
            maxDeleverageCollateralRatioBPS=2500,
            minAccountBorrowSize=50_000e8,
            excessCashLiquidationBonus=101
        ),
        100_000_000e8,
    )

    with brownie.reverts("Must Liquidate All Debt"):
        depositAmount = 7e8
        environment.notional.deleverageAccount(
            accounts[1],
            vault,
            accounts[2],
            1,
            depositAmount,
            {"from": accounts[2], "value": depositAmount * 1e10 }
        )

    # Can deleverage even though the other currency is below the min borrow
    depositAmount = 5e8
    environment.notional.deleverageAccount(
        accounts[1],
        vault,
        accounts[2],
        1,
        depositAmount,
        {"from": accounts[2], "value": depositAmount * 1e10 }
    )

    check_system_invariants(environment, accounts, [vault])