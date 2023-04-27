import brownie
import pytest
from brownie import MockERC20, SimpleStrategyVault
from brownie.network.state import Chain
from brownie.test import given, strategy
from fixtures import *
from tests.constants import PRIME_CASH_VAULT_MATURITY, SECONDS_IN_MONTH, SECONDS_IN_QUARTER 
from tests.helpers import get_balance_trade_action
from tests.internal.vaults.fixtures import get_vault_config, set_flags, get_vault_account, get_vault_state
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()

"""
Authentication
    - Liquidator is valid (test_deleverage_authentication, test_disable_deleverage)
    - Sufficient collateral (test_deleverage_account_sufficient_collateral)
    - Account must be settled ()

Calculate Amount to Liquidate
    - Assume the calculation is correct
    - Validate that view method matches txn method

Account Updates
    - Validate account collateral ratio increases
    - Validate account cash balance
    - Liquidation for secondary currencies
    - Liquidate with PV, without PV

Transfer
    - Transfer Shares to Liquidator
    - Redeem Shares
"""


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_deleverage_authentication(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True, ONLY_VAULT_DELEVERAGE=1)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vault.setExchangeRate(0.85e18)
    (h, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    assert h["collateralRatio"] < 0.2e9

    with brownie.reverts(""):
        # Only vault can call liquidation
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[2]}
        )

    with brownie.reverts(""):
        # Liquidator cannot equal account
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 0, 25_000e18, {"from": vault.address}
        )

    # Anyone can call deleverage now
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )

    with brownie.reverts(""):
        # Cannot liquidate self
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[1], 0, 25_000e18, {"from": accounts[1]}
        )

    with brownie.reverts(""):
        # Cannot liquidate self, second test
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[1]}
        )

    with brownie.reverts(""):
        # Liquidator must equal msg.sender
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[3]}
        )

    with brownie.reverts(""):
        # Vault cannot liquidate
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": vault.address}
        )

    with brownie.reverts(dev_revert_msg="dev: unauthorized"):
        config = get_vault_config()
        vaultConfig = [vault.address] + config[0:10] + [(0, 0, 0), 0] + config[11:]
        environment.notional.calculateDepositAmountInDeleverage(
            0, get_vault_account(), vaultConfig, get_vault_state(), 0
        )

def test_disable_deleverage(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )
    vault.setExchangeRate(0.85e18)
    (h, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)
    assert h["collateralRatio"] < 0.2e9

    # Only owner can set deleverage status
    with brownie.reverts("Ownable: caller is not the owner"):
        environment.notional.setVaultDeleverageStatus(vault.address, True, {"from": accounts[1]})

    environment.notional.setVaultDeleverageStatus(vault.address, True, {"from": accounts[0]})

    # Cannot deleverage
    with brownie.reverts():
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[2]}
        )

    environment.notional.setVaultDeleverageStatus(vault.address, False, {"from": accounts[0]})

    # Can deleverage
    environment.notional.deleverageAccount(
        accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[2]}
    )


def test_deleverage_account_sufficient_collateral(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    with brownie.reverts("Sufficient Collateral"):
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[2]}
        )

    check_system_invariants(environment, accounts, [vault])


def test_cannot_deleverage_account_after_maturity(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.85e18)
    chain.mine(1, timestamp=maturity)

    with brownie.reverts():
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 100_000e18, {"from": accounts[2]}
        )


def test_cannot_transfer_mismatched_shares(environment, accounts, vault):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(currencyId=2, flags=set_flags(0, ENABLED=True)),
        100_000_000e8,
    )
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    # Set up the liquidator such that they have matured vault shares
    environment.notional.enterVault(
        accounts[2], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[2]}
    )

    chain.mine(1, timestamp=maturity)
    environment.notional.initializeMarkets(2, False, {"from": accounts[0]})
    maturity = environment.notional.getActiveMarkets(1)[0][1]

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
    )

    vault.setExchangeRate(0.95e18)

    with brownie.reverts("Maturity Mismatch"):
        # account[2] cannot liquidate this account because they have vault shares
        environment.notional.deleverageAccount(
            accounts[1], vault.address, accounts[2], 0, 25_000e18, {"from": accounts[2]}
        )


"""
Deleverage Scenarios:
 - Over max liquidate amount, cut liquidator down
 - Liquidate part of an account (regular conditions)
 - Liquidate entire account, under min borrow
 - Liquidate an account with vault prime cash
 - Liquidate as a result of interest rate moves

Post Deleverage Scenarios:
 - Can settle
 - Can exit
 - Can re-enter
 - Can roll
 - Liquidate an account a second time (holding temp cash)
"""


def setup_deleverage_conditions(
    environment, accounts, currencyId, isPrime, enablefCashDiscount, vaultPrice
):
    decimals = environment.notional.getCurrency(currencyId)["underlyingToken"]["decimals"]
    vault = SimpleStrategyVault.deploy(
        "Simple Strategy", environment.notional.address, currencyId, {"from": accounts[0]}
    )
    vault.setExchangeRate(1e18)
    # Set a multiple because ETH liquidity is lower in the test environment
    multiple = 1 if currencyId == 1 else 1_000

    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=currencyId,
            flags=set_flags(
                0, ENABLED=True, ENABLE_FCASH_DISCOUNT=enablefCashDiscount, ALLOW_ROLL_POSITION=True
            ),
            minAccountBorrowSize=50 * multiple,
        ),
        100_000_000e8,
    )

    maturity = (
        PRIME_CASH_VAULT_MATURITY
        if isPrime
        else environment.notional.getActiveMarkets(currencyId)[0][1]
    )

    environment.notional.enterVault(
        accounts[1],
        vault.address,
        50 * multiple * decimals,
        maturity,
        200 * multiple * 1e8,
        0,
        "",
        {"from": accounts[1], "value": 50 * multiple * decimals if currencyId == 1 else 0},
    )

    if currencyId != 1:
        token = MockERC20.at(
            environment.notional.getCurrency(currencyId)["underlyingToken"]["tokenAddress"]
        )
    else:
        token = None

    vault.setExchangeRate(vaultPrice * 1e18)

    if currencyId == 1:
        balanceBefore = accounts[2].balance()
    else:
        balanceBefore = token.balanceOf(accounts[2])
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    vaultStateBefore = environment.notional.getVaultState(vault, maturity)

    (
        healthBefore,
        maxLiquidateDebt,
        vaultSharesToLiquidator,
    ) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)

    return {
        "vault": vault,
        "maturity": maturity,
        "decimals": decimals,
        "token": token,
        "multiple": multiple,
        "balanceBefore": balanceBefore,
        "vaultAccountBefore": vaultAccountBefore,
        "vaultStateBefore": vaultStateBefore,
        "collateralRatioBefore": healthBefore["collateralRatio"],
        "maxLiquidateDebt": maxLiquidateDebt[0],
        "vaultSharesToLiquidator": vaultSharesToLiquidator[0],
    }


def check_deleverage_invariants(
    environment, accounts, currencyId, actualDepositAmount, vaultSharesToLiquidator, vaultPrice, e
):
    if currencyId == 1:
        balanceAfter = accounts[2].balance()
    else:
        balanceAfter = e["token"].balanceOf(accounts[2])

    vault = e["vault"]
    maturity = e["maturity"]
    decimals = e["decimals"]

    vaultStateAfter = environment.notional.getVaultState(vault, maturity)
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    (healthAfter, _, _) = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)

    # NOTE: uses rel=1e-5 precision on comparisons due to fCash discounting, will see some drift in
    # values due to passage of time

    assert (
        e["collateralRatioBefore"] < healthAfter["collateralRatio"]
        and healthAfter["collateralRatio"] <= 0.4e9
    )  # this is the collateral ratio at max deposit
    vaultSharesSold = e["vaultAccountBefore"]["vaultShares"] - vaultAccountAfter["vaultShares"]
    # Shares sold is approx equal to amount deposited scaled by the exchange rate and multiplied by
    # the liquidation discount
    assert pytest.approx(vaultSharesSold, rel=1e-04) == (actualDepositAmount * 1.04 / vaultPrice)
    assert pytest.approx(vaultSharesSold, rel=1e-04) == vaultSharesToLiquidator
    assert e["vaultAccountBefore"]["maturity"] == vaultAccountAfter["maturity"]

    if vaultAccountAfter["maturity"] == PRIME_CASH_VAULT_MATURITY:
        # If in prime cash, debt is paid down directly
        assert (
            pytest.approx(
                vaultAccountAfter["accountDebtUnderlying"]
                - e["vaultAccountBefore"]["accountDebtUnderlying"],
                rel=1e-5,
            )
            == actualDepositAmount
        )
    else:
        # Account is now holding the deposit in their temp cash balance and debt has not changed
        assert (
            pytest.approx(
                environment.notional.convertCashBalanceToExternal(
                    currencyId, vaultAccountAfter["tempCashBalance"], True
                ),
                rel=1e-4,
            )
            == actualDepositAmount * decimals / 1e8
        )
        assert (
            vaultAccountAfter["accountDebtUnderlying"]
            == e["vaultAccountBefore"]["accountDebtUnderlying"]
        )

    # Liquidator is holding vault shares and has paid deposit amount
    assert (
        pytest.approx(balanceAfter - e["balanceBefore"], rel=1e-4)
        == -actualDepositAmount * decimals / 1e8
    )
    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
    assert liquidatorAccount["accountDebtUnderlying"] == 0
    assert liquidatorAccount["maturity"] == maturity
    assert pytest.approx(liquidatorAccount["vaultShares"], 10) == vaultSharesToLiquidator
    assert e["vaultStateBefore"]["totalVaultShares"] == vaultStateAfter["totalVaultShares"]

    check_system_invariants(environment, accounts, [vault])

@given(
    currencyId=strategy("uint", min_value=1, max_value=3),
    isPrime=strategy("bool"),
    enablefCashDiscount=strategy("bool"),
    deleverageShare=strategy("uint", min_value=80, max_value=120),
)
def test_deleverage_account_partial(
    environment, accounts, currencyId, isPrime, enablefCashDiscount, deleverageShare
):
    isPrime = False
    # TODO: if we reduce the vault price, we may need to liquidate full...
    vaultPrice = 0.955
    e = setup_deleverage_conditions(
        environment, accounts, currencyId, isPrime, enablefCashDiscount, vaultPrice
    )

    depositAmount = e["maxLiquidateDebt"] * deleverageShare / 100
    with EventChecker(environment, 'Vault Deleverage [Prime]' if isPrime else 'Vault Deleverage [fCash]',
        vaults=[e['vault']]
    ) as c:
        txn = environment.notional.deleverageAccount(
            accounts[1],
            e["vault"].address,
            accounts[2],
            0,
            depositAmount,
            {"from": accounts[2], "value": depositAmount * 1e10 + 1e10 if currencyId == 1 else 0},
        )
        c['txn'] = txn

    # Liquidator is not allowed to go above max liquidate debt
    actualDepositAmount = min(depositAmount, e["maxLiquidateDebt"])
    vaultSharesToLiquidator = (
        e["vaultSharesToLiquidator"] * deleverageShare / 100
        if deleverageShare < 100
        else e["vaultSharesToLiquidator"]
    )

    check_deleverage_invariants(
        environment,
        accounts,
        currencyId,
        actualDepositAmount,
        vaultSharesToLiquidator,
        vaultPrice,
        e,
    )


# Setup a deleveraged account for testing
def deleveraged_account(environment, accounts, currencyId, enablefCashDiscount):
    vaultPrice = 0.96
    e = setup_deleverage_conditions(
        environment, accounts, currencyId, False, enablefCashDiscount, vaultPrice
    )

    depositAmount = e["maxLiquidateDebt"]
    environment.notional.deleverageAccount(
        accounts[1],
        e["vault"].address,
        accounts[2],
        0,
        depositAmount,
        {"from": accounts[2], "value": depositAmount * 1e10 + 1e10 if currencyId == 1 else 0},
    )

    return (e["vault"], accounts[1], e)


@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidator_can_exit_vault_shares(environment, accounts, currencyId, enablefCashDiscount):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
    health = environment.notional.getVaultAccountHealthFactors(accounts[2], vault)["h"]

    if currencyId == 1:
        balanceBefore = accounts[2].balance()
    else:
        balanceBefore = e["token"].balanceOf(accounts[2])

    with EventChecker(environment, 'Vault Exit', vaults=[e['vault']]) as c:
        txn = environment.notional.exitVault(
            accounts[2],
            vault,
            accounts[2],
            liquidatorAccount["vaultShares"],
            0,
            0,
            "",
            {"from": accounts[2]},
        )
        c['txn'] = txn

    if currencyId == 1:
        balanceAfter = accounts[2].balance()
    else:
        balanceAfter = e["token"].balanceOf(accounts[2])

    assert (
        pytest.approx(balanceAfter - balanceBefore, rel=1e-6)
        == health["vaultShareValueUnderlying"] * e["decimals"] / 1e8
    )
    liquidatorAccount = environment.notional.getVaultAccount(accounts[2], vault)
    assert liquidatorAccount["vaultShares"] == 0
    assert liquidatorAccount["accountDebtUnderlying"] == 0
    assert liquidatorAccount["maturity"] == 0

    check_system_invariants(environment, accounts, [vault])

@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidator_can_liquidate_cash(environment, accounts, currencyId, enablefCashDiscount):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    with brownie.reverts("Insufficient free collateral"):
        environment.notional.liquidateVaultCashBalance(
            accounts[1],
            vault,
            accounts[2],
            0,
            -vaultAccountBefore["accountDebtUnderlying"],
            {"from": accounts[2]},
        )

    depositAmount = -vaultAccountBefore["accountDebtUnderlying"] * e["decimals"] / 1e8
    action = get_balance_trade_action(
        currencyId,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Lend",
                "marketIndex": 1,
                "notional": -vaultAccountBefore["accountDebtUnderlying"],
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
        {"from": accounts[2], "value": depositAmount if currencyId == 1 else 0},
    )

    portfolioBefore = environment.notional.getAccountPortfolio(accounts[2])
    (cash, _, _) = environment.notional.getAccountBalance(currencyId, accounts[2])
    assert cash == 0

    (fCashRequired, _) = environment.notional.getfCashRequiredToLiquidateCash(
        currencyId,
        vaultAccountBefore['maturity'],
        vaultAccountBefore['tempCashBalance']
    )

    with EventChecker(environment, 'Vault Liquidate Cash', vaults=[vault]) as e:
        txn = environment.notional.liquidateVaultCashBalance(
            accounts[1],
            vault,
            accounts[2],
            0,
            -vaultAccountBefore["accountDebtUnderlying"],
            {"from": accounts[2]},
        )
        e['txn'] = txn

    # Should receive cash in exchange for fCash
    (cash, _, _) = environment.notional.getAccountBalance(currencyId, accounts[2])
    assert cash == vaultAccountBefore["tempCashBalance"]
    # fCash has been net off
    portfolioAfter = environment.notional.getAccountPortfolio(accounts[2])
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    # fCash has been transferred between accounts
    assert portfolioBefore[0][3] - portfolioAfter[0][3] == (
        vaultAccountAfter["accountDebtUnderlying"] - vaultAccountBefore["accountDebtUnderlying"]
    )
    assert pytest.approx(portfolioBefore[0][3] - portfolioAfter[0][3], abs=150) == fCashRequired
    # Cash has been cleared
    assert vaultAccountAfter["tempCashBalance"] == 0

    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidated_can_enter(environment, accounts, currencyId, enablefCashDiscount):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    healthBefore = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)["h"]

    (borrowAmountUnderlying, _, _, _) = environment.notional.getPrincipalFromfCashBorrow(
        currencyId, 125 * e["multiple"] * 1e8, vaultAccountBefore["maturity"], 0, chain.time()
    )

    with EventChecker(environment, 'Vault Entry', vaults=[vault]) as e:
        txn = environment.notional.enterVault(
            accounts[1],
            vault,
            75 * e["multiple"] * e["decimals"],
            vaultAccountBefore["maturity"],
            125 * e["multiple"] * 1e8,
            0,
            "",
            {
                "from": accounts[1],
                "value": 75 * e["multiple"] * e["decimals"] if currencyId == 1 else 0,
            },
        )
        e['txn'] = txn

    # vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    # healthAfter = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)["h"]
    # totalFees = (
    #     txn.events["VaultFeeAccrued"]["reserveFee"] + txn.events["VaultFeeAccrued"]["nTokenFee"]
    # )

    # assert pytest.approx(healthAfter["vaultShareValueUnderlying"], rel=1e-6) == (
    #     healthBefore["vaultShareValueUnderlying"]
    #     + borrowAmountUnderlying * 1e8 / e["decimals"]
    #     + 75 * e["multiple"] * 1e8
    #     + environment.notional.convertCashBalanceToExternal(
    #         currencyId, vaultAccountBefore["tempCashBalance"] - totalFees, True
    #     )
    #     * 1e8
    #     / e["decimals"]
    # )
    # assert (
    #     vaultAccountAfter["accountDebtUnderlying"]
    #     == vaultAccountBefore["accountDebtUnderlying"] - 125 * e["multiple"] * 1e8
    # )
    # assert vaultAccountAfter["tempCashBalance"] == 0

    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidated_can_settle(environment, accounts, currencyId, enablefCashDiscount):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    chain.mine(1, timestamp=vaultAccountBefore["maturity"])
    environment.notional.initializeMarkets(currencyId, False)
    with EventChecker(environment, 'Vault Settle', vaults=[vault]) as e:
        txn = environment.notional.settleVaultAccount(accounts[1], vault)
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    cashInUnderlying = (
        environment.notional.convertCashBalanceToExternal(
            currencyId, vaultAccountBefore["tempCashBalance"], True
        )
        * 1e8
        / e["decimals"]
    )
    assert pytest.approx(vaultAccountAfter["accountDebtUnderlying"], abs=500) == (
        vaultAccountBefore["accountDebtUnderlying"] + cashInUnderlying
    )
    assert vaultAccountAfter["tempCashBalance"] == 0

    check_system_invariants(environment, accounts, [vault])

@pytest.mark.todo
def test_liquidated_can_settle_with_cash_transfer(environment, accounts, currencyId, enablefCashDiscount):
    # TODO: fill out this test
    pass


@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidated_can_exit(environment, accounts, currencyId, enablefCashDiscount):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    health = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)["h"]
    chain.mine(1, timedelta=60)

    cashInUnderlying = environment.notional.convertCashBalanceToExternal(
        currencyId, vaultAccountBefore["tempCashBalance"], True
    )

    (costToRepay, _, _, _) = environment.notional.getDepositFromfCashLend(
        currencyId,
        -vaultAccountBefore["accountDebtUnderlying"],
        vaultAccountBefore["maturity"],
        0,
        chain.time(),
    )
    expectedCost = (
        cashInUnderlying + health["vaultShareValueUnderlying"] * e["decimals"] / 1e8 - costToRepay
    )

    if currencyId == 1:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = e["token"].balanceOf(accounts[1])

    with EventChecker(environment, 'Vault Exit', vaults=[vault]) as e:
        txn = environment.notional.exitVault(
            accounts[1],
            vault,
            accounts[1],
            vaultAccountBefore["vaultShares"],
            -vaultAccountBefore["accountDebtUnderlying"],
            0,
            "",
            {"from": accounts[1]},
        )
        e['txn'] = txn

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
    else:
        balanceAfter = e["token"].balanceOf(accounts[1])

    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-5) == expectedCost
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    assert vaultAccountAfter["tempCashBalance"] == 0
    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidated_can_roll(environment, accounts, currencyId, enablefCashDiscount):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)
    health = environment.notional.getVaultAccountHealthFactors(accounts[1], vault)["h"]

    # Does not require additional deposit to roll, cash will cover the interest payment. Roll
    # the debt outstanding from the vault health calculation. This will ensure that cash balances
    # pay off the existing debt before rolling into the new maturity at a lower debt level
    with EventChecker(environment, 'Vault Roll', vaults=[vault]) as e:
        txn = environment.notional.rollVaultPosition(
            accounts[1],
            vault,
            -health["totalDebtOutstandingInPrimary"] * 1.06,
            vaultAccountBefore["maturity"] + SECONDS_IN_QUARTER,
            0,
            0,
            0,
            "",
            {"from": accounts[1]},
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    assert vaultAccountAfter["tempCashBalance"] == 0
    check_system_invariants(environment, accounts, [vault])


@given(currencyId=strategy("uint", min_value=1, max_value=3), enablefCashDiscount=strategy("bool"))
def test_liquidated_can_liquidate_second_time(
    environment, accounts, currencyId, enablefCashDiscount
):
    (vault, account, e) = deleveraged_account(
        environment, accounts, currencyId, enablefCashDiscount
    )
    vaultAccountBefore = environment.notional.getVaultAccount(accounts[1], vault)

    vault.setExchangeRate(0.80e18)
    (health, maxDeposit, vaultShares) = environment.notional.getVaultAccountHealthFactors(
        accounts[1], vault
    )
    depositAmount = maxDeposit[0] * e["decimals"] / 1e8
    with EventChecker(environment, 'Vault Deleverage', vaults=[vault]) as e:
        txn = environment.notional.deleverageAccount(
            accounts[1],
            vault.address,
            accounts[2],
            0,
            maxDeposit[0],
            {"from": accounts[2], "value": depositAmount + 1e10 if currencyId == 1 else 0},
        )
        e['txn'] = txn

    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], vault)
    symbol = environment.symbol[currencyId]
    # FLAKY
    assert environment.approxInternal(
        symbol,
        vaultAccountAfter["tempCashBalance"] - vaultAccountBefore["tempCashBalance"],
        maxDeposit[0],
        abs=50_000
    )

    check_system_invariants(environment, accounts, [vault])


def setup_deleverage_account_over_debt_balance(
    environment, accounts, currencyId
):
    vaultPrice = 0.875
    e = setup_deleverage_conditions(
        environment, accounts, currencyId, False, False, vaultPrice
    )
    # Setup some prime debt so that we start to accrue interest
    environment.notional.enablePrimeBorrow(True, {"from": accounts[0]})
    environment.notional.withdraw(currencyId, 5000e8 if currencyId == 1 else 500_000e8, True, {"from": accounts[0]})

    depositAmount = e["maxLiquidateDebt"]
    environment.notional.deleverageAccount(
        accounts[1],
        e["vault"].address,
        accounts[2],
        0,
        depositAmount,
        {"from": accounts[2], "value": depositAmount * 1e10 + 1e10 if currencyId == 1 else 0},
    )
    accountAfter = environment.notional.getVaultAccount(accounts[1], e['vault'])

    chain.mine(1, timedelta=SECONDS_IN_MONTH)
    # Check that the value of the cash is greater than the value of the debt
    assert -accountAfter['accountDebtUnderlying'] * e['decimals'] / 1e8 < environment.notional.convertCashBalanceToExternal(currencyId, accountAfter['tempCashBalance'], True)

    return e

@given(currencyId=strategy("uint", min_value=1, max_value=3))
def test_excess_cash_can_exit(environment, accounts, currencyId):
    e = setup_deleverage_account_over_debt_balance(environment, accounts, currencyId)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], e['vault'])
    if currencyId == 1:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = e['token'].balanceOf(accounts[1])

    (
        health,
        _,
        _
    ) = environment.notional.getVaultAccountHealthFactors(accounts[1], e['vault'])

    costToLendUnderlying = environment.notional.getDepositFromfCashLend(
        currencyId,
        -vaultAccount['accountDebtUnderlying'],
        vaultAccount['maturity'],
        0,
        chain.time()
    )['depositAmountUnderlying']

    cashInUnderlying = environment.notional.convertCashBalanceToExternal(currencyId, vaultAccount['tempCashBalance'], True)

    # NOTE: the excess cash is included in vault share value underlying returned here
    expectedUnderlyingWithdraw = cashInUnderlying - costToLendUnderlying + ((health['vaultShareValueUnderlying'] - health['netDebtOutstanding'][0]) * e["decimals"] / 1e8)

    txn = environment.notional.exitVault(
        accounts[1],
        e['vault'],
        accounts[1],
        vaultAccount['vaultShares'],
        -vaultAccount['accountDebtUnderlying'],
        0,
        "",
        {"from": accounts[1]}
    )

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
    else:
        balanceAfter = e['token'].balanceOf(accounts[1])

    assert pytest.approx(expectedUnderlyingWithdraw, rel=1e-5) == balanceAfter - balanceBefore
    check_system_invariants(environment, accounts, [e['vault']])

@given(currencyId=strategy("uint", min_value=1, max_value=3))
def test_excess_cash_can_settle(environment, accounts, currencyId):
    e = setup_deleverage_account_over_debt_balance(environment, accounts, currencyId)
    vaultAccount = environment.notional.getVaultAccount(accounts[1], e['vault'])
    chain.mine(1, timestamp=vaultAccount['maturity'])

    environment.notional.initializeMarkets(currencyId, False)

    if currencyId == 1:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = e['token'].balanceOf(accounts[1])

    (
        health,
        _,
        _
    ) = environment.notional.getVaultAccountHealthFactors(accounts[1], e['vault'])

    txn = environment.notional.settleVaultAccount(
        accounts[1],
        e['vault'],
        {"from": accounts[1]}
    )

    if currencyId == 1:
        balanceAfter = accounts[1].balance()
    else:
        balanceAfter = e['token'].balanceOf(accounts[1])

    assert balanceBefore == balanceAfter
    vaultAccountAfter = environment.notional.getVaultAccount(accounts[1], e['vault'])
    assert environment.approxInternal(environment.symbol[currencyId], vaultAccountAfter['tempCashBalance'], health['netDebtOutstanding'][0])
    check_system_invariants(environment, accounts, [e['vault']])
