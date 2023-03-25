import logging

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from scripts.config import CurrencyDefaults
from tests.constants import RATE_PRECISION, SECONDS_IN_DAY, SECONDS_IN_QUARTER, SECONDS_IN_YEAR
from tests.helpers import (
    get_balance_action,
    get_balance_trade_action,
    get_interest_rate_curve,
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
    (primeRate, _, _, _) = environment.notional.getPrimeFactors(currencyId, chain.time() + 1)
    markets = environment.notional.getActiveMarkets(currencyId)
    for (i, market) in enumerate(markets):
        totalCashUnderlying = (market[3] * primeRate["supplyFactor"]) / Wei(1e36)
        proportion = int(market[2] * RATE_PRECISION / (totalCashUnderlying + market[2]))
        proportions.append(proportion)

    return proportions


def test_deleverage_markets_no_lend(environment, accounts):
    # Lending does not succeed when markets are over levered, cash goes into cash balance
    currencyId = 2
    environment.notional.updateDepositParameters(currencyId, [0.4e8, 0.6e8], [0.4e9, 0.4e9])

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)
    marketsBefore = environment.notional.getActiveMarkets(currencyId)
    reserveBalanceBefore = environment.notional.getReserveBalance(currencyId)

    txn = environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintNToken", depositActionAmount=50000000e8
            )
        ],
        {"from": accounts[0]},
    )
    LOGGER.info("NO LEND GAS COST: {}".format(txn.gas_used))

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    balanceAfter = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    marketsAfter = environment.notional.getActiveMarkets(currencyId)
    reserveBalanceAfter = environment.notional.getReserveBalance(currencyId)

    assert portfolioBefore == portfolioAfter
    assert ifCashAssetsBefore == ifCashAssetsAfter
    assert environment.approxInternal("DAI", balanceAfter[0], 1_000_000e8)
    assert marketsBefore == marketsAfter
    assert reserveBalanceBefore == reserveBalanceAfter

    check_system_invariants(environment, accounts)

def test_deleverage_markets_lend(environment, accounts):
    # Lending does succeed with a smaller balance
    currencyId = 2
    environment.notional.updateDepositParameters(currencyId, [0.4e8, 0.6e8], [0.4e9, 0.4e9])

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)
    marketProportionsBefore = get_market_proportion(currencyId, environment)
    reserveBalanceBefore = environment.notional.getReserveBalance(currencyId)

    txn = environment.notional.batchBalanceAction(
        accounts[0],
        [get_balance_action(currencyId, "DepositAssetAndMintNToken", depositActionAmount=50_000e8)],
        {"from": accounts[0]},
    )
    LOGGER.info("LEND GAS COST: {}".format(txn.gas_used))

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    balanceAfter = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    reserveBalanceAfter = environment.notional.getReserveBalance(currencyId)
    marketProportionsAfter = get_market_proportion(currencyId, environment)

    assert portfolioBefore == portfolioAfter

    for (assetBefore, assetAfter) in zip(ifCashAssetsBefore, ifCashAssetsAfter):
        assert assetBefore[3] < assetAfter[3]

    for (proportionBefore, proportionAfter) in zip(marketProportionsBefore, marketProportionsAfter):
        assert proportionBefore > proportionAfter

    # Minimum residual left
    assert balanceAfter[0] < 500e8
    assert reserveBalanceAfter - reserveBalanceBefore > 0

    check_system_invariants(environment, accounts)


def test_deleverage_markets_lend_and_provide(environment, accounts):
    # Lending does not succeed when markets are over levered, cash goes into cash balance
    currencyId = 2
    environment.notional.updateDepositParameters(currencyId, [0.4e8, 0.6e8], [0.49999e9, 0.49999e9])

    nTokenAddress = environment.notional.nTokenAddress(currencyId)
    (portfolioBefore, ifCashAssetsBefore) = environment.notional.getNTokenPortfolio(nTokenAddress)
    marketProportionsBefore = get_market_proportion(currencyId, environment)
    reserveBalanceBefore = environment.notional.getReserveBalance(currencyId)

    txn = environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintNToken", depositActionAmount=500_000e8
            )
        ],
        {"from": accounts[0]},
    )
    LOGGER.info("LEND AND PROVIDE GAS COST: {}".format(txn.gas_used))

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    balanceAfter = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    reserveBalanceAfter = environment.notional.getReserveBalance(currencyId)
    marketProportionsAfter = get_market_proportion(currencyId, environment)

    for (assetBefore, assetAfter) in zip(portfolioBefore, portfolioAfter):
        assert assetBefore[3] < assetAfter[3]

    for (assetBefore, assetAfter) in zip(ifCashAssetsBefore, ifCashAssetsAfter):
        assert assetBefore[3] < assetAfter[3]

    for (proportionBefore, proportionAfter) in zip(marketProportionsBefore, marketProportionsAfter):
        assert proportionBefore > proportionAfter

    # No residual left
    assert balanceAfter[0] == 0
    assert reserveBalanceAfter - reserveBalanceBefore > 0

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

    environment.token["DAI"].transfer(accounts[2], 5000e18, {"from": accounts[0]})
    environment.token["DAI"].approve(environment.notional.address, 2 ** 255, {"from": accounts[2]})
    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [
            {
                "tradeActionType": "PurchaseNTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
        depositActionAmount=100e18,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[2], [action], {"from": accounts[2]})

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceAfter, _, _) = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    (accountCashBalance, _, _) = environment.notional.getAccountBalance(currencyId, accounts[2])
    accountPortfolio = environment.notional.getAccountPortfolio(accounts[2])

    depositAmountPrimeCash = environment.notional.convertUnderlyingToPrimeCash(2, 100e18)
    assert portfolioAfter == portfolioBefore
    assert accountCashBalance == cashBalanceBefore - cashBalanceAfter + depositAmountPrimeCash
    assert accountPortfolio[0][0:3] == ifCashAssetsBefore[2][0:3]
    assert len(ifCashAssetsAfter) == 3

    check_system_invariants(environment, accounts)


def test_purchase_ntoken_residual_positive(environment, accounts):
    currencyId = 2
    setup_residual_environment(
        environment, accounts, residualType=2, marketResiduals=False, canSellResiduals=True
    )
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

    with brownie.reverts("No Prime Borrow"):
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
        "DepositUnderlying",
        [
            {
                "tradeActionType": "PurchaseNTokenResidual",
                "maturity": ifCashAssetsBefore[2][1],
                "fCashAmountToPurchase": ifCashAssetsBefore[2][3],
            }
        ],
        depositActionAmount=110e18,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[0], [action], {"from": accounts[0]})

    (portfolioAfter, ifCashAssetsAfter) = environment.notional.getNTokenPortfolio(nTokenAddress)
    (cashBalanceAfter, _, _) = environment.notional.getAccountBalance(currencyId, nTokenAddress)
    (accountCashBalance, _, _) = environment.notional.getAccountBalance(currencyId, accounts[0])
    accountPortfolio = environment.notional.getAccountPortfolio(accounts[0])

    depositAmountPrimeCash = environment.notional.convertUnderlyingToPrimeCash(2, 110e18)
    assert portfolioAfter == portfolioBefore
    assert depositAmountPrimeCash - accountCashBalance == cashBalanceAfter
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

    # Don't check invariants b/c we don't init markets in between


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
    # Don't check invariants b/c we don't init markets in between


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


def test_purchase_ntoken_residual_and_sweep_cash(environment, accounts):
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

    environment.notional.updateInterestRateCurve(
        currencyId, [1, 2, 3, 4], [get_interest_rate_curve()] * 4
    )
    environment.notional.updateInitializationParameters(
        currencyId, [0, 0, 0, 0], [0.5e9, 0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=blockTime + SECONDS_IN_QUARTER)
    for (cid, _) in environment.nToken.items():
        try:
            environment.notional.initializeMarkets(cid, False)
        except Exception:
            pass

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
    for (cid, _) in environment.nToken.items():
        try:
            environment.notional.initializeMarkets(cid, False)
        except Exception:
            pass

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

@given(useBitmap=strategy("bool"))
def test_mint_and_redeem_with_supply_caps(environment, accounts, useBitmap):
    currencyId = 2
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    factors = environment.notional.getPrimeFactorsStored(currencyId)
    environment.notional.setMaxUnderlyingSupply(currencyId, factors['lastTotalUnderlyingValue'] + 1e8)

    with brownie.reverts("Over Supply Cap"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(
                    currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=1_000e18
                )
            ],
            {"from": accounts[0]},
        )

    factors = environment.notional.getPrimeFactorsStored(currencyId)
    environment.notional.setMaxUnderlyingSupply(
        currencyId,
        factors['lastTotalUnderlyingValue'] + 1_050e8
    )
    
    environment.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=1_000e18
            )
        ],
        {"from": accounts[0]},
    )

    environment.notional.setMaxUnderlyingSupply(currencyId, 1e8)

    # In this edge condition, the account cannot redeem nTokens via the batch action. They
    # have to use account action
    with brownie.reverts("Over Supply Cap"):
        environment.notional.batchBalanceAction(
            accounts[0],
            [
                get_balance_action(
                    currencyId,
                    "RedeemNToken",
                    depositActionAmount=500e8,
                    withdrawEntireCashBalance=True
                )
            ],
            {"from": accounts[0]},
        )

    # Neither of these methods have supply cap checks
    environment.notional.nTokenRedeem(
        accounts[0],
        currencyId,
        500e8,
        True,
        False,
        {"from": accounts[0]},
    )
    environment.notional.withdraw(currencyId, 2 ** 88 - 1, True, {"from": accounts[0]})

    check_system_invariants(environment, accounts)