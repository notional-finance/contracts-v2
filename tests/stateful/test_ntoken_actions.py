import math
import logging

import brownie
import pytest
from brownie.test import given, strategy
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults
from tests.constants import RATE_PRECISION, SECONDS_IN_DAY, SECONDS_IN_QUARTER, SECONDS_IN_YEAR
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
    initialize_environment,
    setup_residual_environment,
)
from tests.stateful.invariants import check_system_invariants

chain = Chain()
LOGGER = logging.getLogger(__name__)


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def get_market_proportion(currencyId, environment):
    proportions = []
    (cashGroup, assetRate) = environment.notional.getCashGroupAndAssetRate(currencyId)
    markets = environment.notional.getActiveMarkets(currencyId)
    for (i, market) in enumerate(markets):
        totalCashUnderlying = (market[3] * Wei(1e8) * assetRate[1]) / (assetRate[2] * Wei(1e18))
        proportion = int(market[2] * RATE_PRECISION / (totalCashUnderlying + market[2]))
        proportions.append(proportion)

    return proportions

def test_mint_ntokens_above_deviation(environment, accounts):
    currencyId = 2
    environment.notional.updateTokenCollateralParameters(
        2, 20, 80, 24, 100, 94, 3,
        {"from": environment.notional.owner()}
    )
    lendAction = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "Lend",
                "marketIndex": 1,
                "notional": 75_000e8,
                "minSlippage": 0,
            },
            {
                "tradeActionType": "Lend",
                "marketIndex": 2,
                "notional": 75_000e8,
                "minSlippage": 0,
            }
        ],
        depositActionAmount=200_000e18,
        withdrawEntireCashBalance=False,
        redeemToUnderlying=True,
    )
    environment.notional.batchBalanceAndTradeAction(
        accounts[0],
        [ lendAction ],
        {"from": accounts[0]},
    )

    chain.mine(blocks=1, timedelta=21600)

    # Borrow a bunch to move the last implied PV
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": 560_000e8,
                "maxSlippage": 0,
            },
            {
                "tradeActionType": "Borrow",
                "marketIndex": 2,
                "notional": 560_000e8,
                "maxSlippage": 0,
            }
        ],
        withdrawEntireCashBalance=False,
        redeemToUnderlying=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[0],
        [ borrowAction ],
        {"from": accounts[0]},
    )

    # Spot rate and oracle rate should differ by about 8.5% here
    with brownie.reverts("Over Deviation Limit"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(
                    currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=1_000e18
                )
            ],
            {"from": accounts[0]},
        )

    with brownie.reverts("Over Deviation Limit"):
        environment.notional.calculateNTokensToMint(
            currencyId, 1000e18
        )

    # Ensure that the nToken valuation is done at the oracle rate here, the oracle rate will
    # converge over 100 min. Free collateral will decrease as a result because the borrowing
    # has pushed cash into fCash and the fCash has a large discount
    (fc1, (_, dai1, *_)) = environment.notional.getFreeCollateral(accounts[0])

    chain.mine(timedelta=3000) # 50 min

    (fc2, (_, dai2, *_)) = environment.notional.getFreeCollateral(accounts[0])
    assert fc2 < fc1
    assert dai2 < dai1

    chain.mine(timedelta=3000) # 50 min

    (fc3, (_, dai3, *_)) = environment.notional.getFreeCollateral(accounts[0])
    assert pytest.approx(fc2, rel=1e-3) != fc3
    assert pytest.approx(dai2, rel=1e-3) != dai3

    # Should be converged now and can mint tokens again
    chain.mine(timedelta=600) # 10 min

    (fc4, (_, dai4, *_)) = environment.notional.getFreeCollateral(accounts[0])
    assert pytest.approx(fc3, rel=1e-6) == fc4
    assert pytest.approx(dai3, rel=1e-6) == dai4

    # Can mint nTokens again
    environment.notional.calculateNTokensToMint(
        currencyId, 1000e18
    )

    check_system_invariants(environment, accounts)

"""
Test deleverage:
    - Put market above the leverage threshold
    - Lend fails if slippage > deleverage buffer
    - Lend succeeds if slippage < deleverage buffer
"""

DELEVERAGE_BUFFER = 0.03e9

def get_leverage_ratio(environment, currencyId, marketIndex):
    market = environment.notional.getActiveMarkets(currencyId)[marketIndex - 1]
    cashUnderlying = environment.notional.convertCashBalanceToExternal(
        currencyId, market[3], True
    ) * 1e8 / 1e18

    return market[2] / (market[2] + cashUnderlying)

def get_lend_slippage(environment, currencyId, marketIndex, depositAmount):
    market = environment.notional.getActiveMarkets(currencyId)[marketIndex - 1]
    (fCashAmount, *_) = environment.notional.getfCashLendFromDeposit(
        currencyId, depositAmount, market[1], 0, chain.time(), True
    )
    exchangeRate = fCashAmount / (depositAmount * 1e8 / 1e18)
    impliedRate = math.floor((math.log(exchangeRate) * SECONDS_IN_YEAR) / (market[1] - chain.time()) * 1e9)
    return market[5] - impliedRate


@pytest.mark.only
@given(
    marketDeposit=strategy("uint256", min_value=100, max_value=100_000),
)
def test_deleverage_markets_lend_fails_too_large(environment, accounts, marketDeposit):
    # Lending does not succeed when markets are over levered, cash goes into cash balance
    currencyId = 2
    (depositShare, leverageThresholds) = environment.notional.getDepositParameters(currencyId)

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)
    assert environment.notional.getNTokenAccount(nTokenAddress)['cashBalance'] == 0

    # Put it slightly over the leverage threshold (~0.814)
    environment.notional.batchBalanceAndTradeAction(
        accounts[0],
        [get_balance_trade_action(
            currencyId, "DepositUnderlying",
            [{ "tradeActionType": "Borrow", "marketIndex": 1, "notional": 325_000e8, "maxSlippage": 0 }],
            redeemToUnderlying=True
        )],
        {"from": accounts[0]}
    )

    marketDeposit = marketDeposit * 1e18
    leverageRatioBefore = get_leverage_ratio(environment, currencyId, 1)
    slippage = get_lend_slippage(environment, currencyId, 1, marketDeposit)
    depositAmount = math.floor(marketDeposit * 1e8 / depositShare[0])

    # Now check that the lend amount will trigger the deleverage buffer
    if slippage > DELEVERAGE_BUFFER:
        # Will trip and cause the txn to fail
        with brownie.reverts("Deleverage Buffer"):
            environment.notional.batchBalanceAction(
                accounts[0],
                [
                    get_balance_action(
                        currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=depositAmount
                    )
                ],
                {"from": accounts[0]},
            )
    else:
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(
                    currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=depositAmount
                )
            ],
            {"from": accounts[0]},
        )

        leverageRatioAfter = get_leverage_ratio(environment, currencyId, 1)
        assert leverageRatioAfter < leverageRatioBefore

        (portfolioAfter, _) = environment.notional.getNTokenPortfolio(nTokenAddress)
        if leverageRatioAfter < (leverageThresholds[0] / 1e9):
            # Should have provided liquidity here with the remaining cash
            # under the leverage threshold
            assert portfolioBefore[0][3] < portfolioAfter[0][3]
        else: 
            # No liquidity provision here while still above the leverage threshold
            assert portfolioBefore[0][3] == portfolioAfter[0][3]
        acct = environment.notional.getNTokenAccount(nTokenAddress)
        
        LOGGER.info("Residual cash {}, {}, {}".format(
            marketDeposit / 1e18, acct['cashBalance'] / 50e8, (acct['cashBalance'] / 50e8) / (marketDeposit / 1e18))
        )

    check_system_invariants(environment, accounts)

def test_purchase_ntoken_residual_negative(environment, accounts):
    currencyId = 2
    setup_residual_environment(
        environment, accounts, residualType=1, marketResiduals=False, canSellResiduals=True
    )

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceBefore, _, _) = environment.notional.getAccountBalance(currencyId, nTokenAddress)

    with brownie.reverts("Insufficient block time"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchaseNTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    with brownie.reverts("Non idiosyncratic maturity"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchaseNTokenResidual",
                    "maturity": ifCashAssetsBefore[1][1],
                    "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    blockTime = chain.time()
    # 96 hour buffer period
    chain.mine(1, timestamp=blockTime + 96 * 3600)

    # TODO: what happened here?
    with brownie.reverts("Invalid amount"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchaseNTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": 100e8,
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    environment.cToken["DAI"].transfer(accounts[2], 5000e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[2]})
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "PurchaseNTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
        depositActionAmount=5000e8,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[2], [action], {"from": accounts[2]})

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceAfter, _, _) = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    (accountCashBalance, _, _) = environment.notional.getAccountBalance(currencyId, accounts[2])
    accountPortfolio = environment.notional.getAccountPortfolio(accounts[2])

    assert portfolioAfter == portfolioBefore
    assert accountCashBalance == cashBalanceBefore - cashBalanceAfter + 5000e8
    assert accountPortfolio[0][0:3] == ifCashAssetsBefore[2][0:3]
    assert len(ifCashAssetsAfter) == 3

    check_system_invariants(environment, accounts)


def test_purchase_perp_token_residual_positive(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[9] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[10] = CurrencyDefaults["rateScalar"][0:3]
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInitializationParameters(
        currencyId, [0.01e9, 0.021e9, 0.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    # Do some trading to leave some perp token residual
    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=10e18)

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, action], {"from": accounts[1], "value": 10e18}
    )

    # Now settle the markets, should be some residual
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceBefore, _, _) = environment.notional.getAccountBalance(currencyId, nTokenAddress)

    blockTime = chain.time()
    # 96 hour buffer period
    chain.mine(1, timestamp=blockTime + 96 * 3600)

    with brownie.reverts("Invalid amount"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchaseNTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": -100e8,
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    with brownie.reverts("Insufficient cash"):
        action = get_balance_trade_action(
            2,
            "None",
            [
                {
                    "tradeActionType": "PurchaseNTokenResidual",
                    "maturity": ifCashAssetsBefore[2][1],
                    "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
                }
            ],
        )
        environment.notional.batchBalanceAndTradeAction(
            accounts[2], [action], {"from": accounts[2]}
        )

    # Use a different account
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "PurchaseNTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
        depositActionAmount=5500e8,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[0], [action], {"from": accounts[0]})

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceAfter, _, _) = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    (accountCashBalance, _, _) = environment.notional.getAccountBalance(currencyId, accounts[0])
    accountPortfolio = environment.notional.getAccountPortfolio(accounts[0])

    assert portfolioAfter == portfolioBefore
    assert 5500e8 - accountCashBalance == cashBalanceAfter
    assert accountPortfolio[0][0:3] == ifCashAssetsBefore[2][0:3]
    assert len(ifCashAssetsAfter) == 3

    check_system_invariants(environment, accounts)


def test_transfer_tokens(environment, accounts):
    currencyId = 2
    totalSupplyBefore = environment.nToken[currencyId].totalSupply()
    assert totalSupplyBefore == environment.nToken[currencyId].balanceOf(accounts[0])
    (_, _, accountOneLastMintTime) = environment.notional.getAccountBalance(currencyId, accounts[1])
    assert accountOneLastMintTime == 0

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + 10 * SECONDS_IN_DAY)
    txn = environment.nToken[currencyId].transfer(accounts[1], 100e8)

    assert txn.events["Transfer"][1]["from"] == accounts[0]
    assert txn.events["Transfer"][1]["to"] == accounts[1]
    assert txn.events["Transfer"][1]["value"] == 100e8
    assert environment.nToken[currencyId].totalSupply() == totalSupplyBefore
    assert environment.nToken[currencyId].balanceOf(accounts[1]) == 100e8
    assert environment.nToken[currencyId].balanceOf(accounts[0]) == totalSupplyBefore - 100e8
    assert environment.noteERC20.balanceOf(accounts[0]) > 0
    assert environment.noteERC20.balanceOf(accounts[1]) == 0

    check_system_invariants(environment, accounts)


def test_cannot_transfer_ntokens_to_self(environment, accounts):
    currencyId = 2
    with brownie.reverts():
        environment.nToken[currencyId].transfer(accounts[0], 100e8, {"from": accounts[0]})


def test_cannot_transfer_ntokens_to_negative_fc(environment, accounts):
    fCashAmount = 100e8
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [
            {
                "tradeActionType": "Borrow",
                "marketIndex": 1,
                "notional": fCashAmount,
                "maxSlippage": 0,
            }
        ],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    collateral = get_balance_trade_action(
        3, "DepositUnderlyingAndMintNToken", [], depositActionAmount=10000e6
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrowAction, collateral], {"from": accounts[1]}
    )
    (_, nTokenBalance, _) = environment.notional.getAccountBalance(3, accounts[1])

    with brownie.reverts("Insufficient free collateral"):
        environment.nToken[3].transfer(accounts[0], nTokenBalance, {"from": accounts[1]})


def test_mint_incentives(environment, accounts):
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_YEAR)
    balanceBefore = environment.noteERC20.balanceOf(accounts[0])
    incentivesClaimed = environment.notional.nTokenGetClaimableIncentives(
        accounts[0].address, chain.time()
    )
    txn = environment.notional.nTokenClaimIncentives()
    balanceAfter = environment.noteERC20.balanceOf(accounts[0])

    assert pytest.approx(incentivesClaimed, rel=1e-7) == (balanceAfter - balanceBefore)
    assert pytest.approx(incentivesClaimed, rel=1e-4) == 100000e8 * 3
    assert (
        environment.notional.nTokenGetClaimableIncentives(accounts[0].address, txn.timestamp) == 0
    )

    check_system_invariants(environment, accounts)


def test_mint_bitmap_incentives(environment, accounts):
    # NOTE: this test is a little flaky when running with the entire test suite
    environment.notional.enableBitmapCurrency(2, {"from": accounts[0]})

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_YEAR)
    balanceBefore = environment.noteERC20.balanceOf(accounts[0])
    incentivesClaimed = environment.notional.nTokenGetClaimableIncentives(
        accounts[0].address, chain.time()
    )
    txn = environment.notional.nTokenClaimIncentives()
    balanceAfter = environment.noteERC20.balanceOf(accounts[0])

    assert pytest.approx(balanceAfter - balanceBefore, rel=1e-6) == incentivesClaimed
    assert pytest.approx(incentivesClaimed, rel=5e-4) == 100000e8 * 3
    assert (
        environment.notional.nTokenGetClaimableIncentives(accounts[0].address, txn.timestamp) == 0
    )

    check_system_invariants(environment, accounts)


def test_cannot_transfer_ntoken_to_ntoken(environment, accounts):
    environment.nToken[2].approve(accounts[1], 200e8, {"from": accounts[0]})

    with brownie.reverts():
        environment.nToken[2].transfer(environment.nToken[3].address, 100e8, {"from": accounts[0]})

    with brownie.reverts():
        environment.nToken[2].transfer(environment.nToken[2].address, 100e8, {"from": accounts[0]})

    with brownie.reverts():
        environment.nToken[2].transferFrom(
            accounts[0].address, environment.nToken[3].address, 100e8, {"from": accounts[1]}
        )

    with brownie.reverts():
        environment.nToken[2].transferFrom(
            accounts[0].address, environment.nToken[2].address, 100e8, {"from": accounts[1]}
        )


def test_transfer_allowance(environment, accounts):
    assert environment.nToken[2].balanceOf(accounts[2]) == 0
    environment.nToken[2].approve(accounts[1], 200e8, {"from": accounts[0]})
    environment.nToken[2].transferFrom(
        accounts[0].address, accounts[2].address, 100e8, {"from": accounts[1]}
    )
    assert environment.nToken[2].balanceOf(accounts[2]) == 100e8


def test_transfer_all_allowance(environment, accounts):
    assert environment.nToken[1].balanceOf(accounts[2]) == 0
    assert environment.nToken[2].balanceOf(accounts[2]) == 0
    environment.notional.nTokenTransferApproveAll(accounts[1], 500e8, {"from": accounts[0]})
    environment.nToken[2].transferFrom(
        accounts[0].address, accounts[2].address, 100e8, {"from": accounts[1]}
    )
    environment.nToken[1].transferFrom(
        accounts[0].address, accounts[2].address, 100e8, {"from": accounts[1]}
    )
    assert environment.nToken[1].balanceOf(accounts[2]) == 100e8
    assert environment.nToken[2].balanceOf(accounts[2]) == 100e8


def test_purchase_perp_token_residual_and_sweep_cash(environment, accounts):
    currencyId = 2
    cashGroup = list(environment.notional.getCashGroup(currencyId))
    # Enable the two year markets
    cashGroup[0] = 4
    cashGroup[9] = CurrencyDefaults["tokenHaircut"][0:4]
    cashGroup[10] = CurrencyDefaults["rateScalar"][0:4]
    environment.notional.updateCashGroup(currencyId, cashGroup)

    environment.notional.updateDepositParameters(
        currencyId, [0.4e8, 0.2e8, 0.2e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9, 0.8e9]
    )

    environment.notional.updateInitializationParameters(
        currencyId, [0.01e9, 0.021e9, 0.07e9, 0.08e9], [0.5e9, 0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    collateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=10e18)
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            # This leaves a positive residual
            {"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0},
            # This leaves a negative residual
            {"tradeActionType": "Lend", "marketIndex": 4, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, action], {"from": accounts[1], "value": 10e18}
    )

    # Now settle the markets, should be some residual
    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    environment.notional.initializeMarkets(currencyId, False)

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)

    blockTime = chain.time()
    # 96 hour buffer period
    chain.mine(1, timestamp=blockTime + 96 * 3600)

    residualPurchaseAction = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "PurchaseNTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
        depositActionAmount=5500e8,
    )
    environment.notional.batchBalanceAndTradeAction(
        accounts[0], [residualPurchaseAction], {"from": accounts[0]}
    )

    (
        _,
        totalSupplyBefore,
        _,
        _,
        _,
        cashBalanceBefore,
        _,
        _,
    ) = environment.notional.getNTokenAccount(nTokenAddress)
    txn = environment.notional.sweepCashIntoMarkets(2)
    (portfolioAfter, _) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (_, totalSupplyAfter, _, _, _, cashBalanceAfter, _, _) = environment.notional.getNTokenAccount(
        nTokenAddress
    )
    cashIntoMarkets = txn.events["SweepCashIntoMarkets"]["cashIntoMarkets"]

    assert totalSupplyBefore == totalSupplyAfter
    assert cashBalanceBefore - cashBalanceAfter == cashIntoMarkets

    for (assetBefore, assetAfter) in zip(portfolioBefore, portfolioAfter):
        assert assetAfter[3] > assetBefore[3]

    check_system_invariants(environment, accounts)


def test_can_reduce_erc20_approval(environment, accounts):
    environment.nToken[2].approve(accounts[1], 200e8, {"from": accounts[0]})
    environment.nToken[2].approve(accounts[1], 100e8, {"from": accounts[0]})
