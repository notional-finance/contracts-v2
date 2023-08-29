import brownie
import pytest
from brownie.test import given, strategy
from brownie.convert.datatypes import HexString
from brownie.network.contract import Contract
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, PrimeCashCurve, nTokenDefaults
from scripts.deployment import TokenType, deployNotionalContracts
from tests.helpers import get_interest_rate_curve, initialize_environment

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_router_initialization(environment, accounts, Router, nProxy):
    cETH = environment.cToken["ETH"]
    (router, pauseRouter, contracts) = deployNotionalContracts(
        accounts[0],
        cETH=cETH.address,
        WETH=cETH.address,
        Comptroller=environment.comptroller.address,
        RebalancingStrategy=brownie.ZERO_ADDRESS
    )

    with brownie.reverts():
        # Cannot call initialize on implementation contract
        router.initialize(accounts[2], pauseRouter, accounts[2], {"from": accounts[0]})

    initializeData = router.initialize.encode_input(
        accounts[0].address, pauseRouter.address, accounts[2]
    )

    with brownie.reverts():
        # Only the deployer can initialize
        proxy = nProxy.deploy(router.address, initializeData, {"from": accounts[2]})
    proxy = nProxy.deploy(router.address, initializeData, {"from": accounts[0]})
    routerProxy = Contract.from_abi("Router", proxy.address, abi=Router.abi, owner=accounts[0])

    with brownie.reverts():
        # Cannot re-initialize
        routerProxy.initialize(accounts[2], pauseRouter, accounts[3])


def test_non_callable_methods(environment, accounts):
    zeroAddress = HexString(0, "bytes20")

    with brownie.reverts("Ownable: caller is not the owner"):
        environment.notional.transferOwnership(accounts[1], True, {"from": accounts[1]})

        environment.notional.upgradeNTokenBeacon(accounts[1], {"from": accounts[1]})

        environment.notional.listCurrency(
            (environment.token["DAI"].address, False, 0, 18, 0),
            (zeroAddress, False, 0, 0, 0),
            zeroAddress,
            False,
            12,
            CurrencyDefaults["buffer"],
            CurrencyDefaults["haircut"],
            CurrencyDefaults["liquidationDiscount"],
            {"from": accounts[1]},
        )

        environment.notional.updateMaxCollateralBalance(1, 100)

        environment.notional.enableCashGroup(
            10,
            zeroAddress,
            (
                CurrencyDefaults["maxMarketIndex"],
                CurrencyDefaults["rateOracleTimeWindow"],
                CurrencyDefaults["maxDiscountRate"],
                CurrencyDefaults["totalFee"],
                CurrencyDefaults["reserveFeeShare"],
                CurrencyDefaults["debtBuffer"],
                CurrencyDefaults["fCashHaircut"],
                CurrencyDefaults["minOracleRate"],
                CurrencyDefaults["liquidationfCashDiscount"],
                CurrencyDefaults["maxOracleRate"],
            ),
            "Ether",
            "ETH",
            {"from": accounts[1]},
        )

        currencyId = 10
        environment.notional.updateDepositParameters(
            currencyId, [0.4e8, 0.6e8], [0.4e9, 0.4e9], {"from": accounts[1]}
        )
        environment.notional.updateInitializationParameters(
            currencyId, [0, 0, 0], [0.5e9, 0.5e9, 0.5e9], {"from": accounts[1]}
        )
        environment.notional.updateIncentiveEmissionRate(
            currencyId, CurrencyDefaults["incentiveEmissionRate"], {"from": accounts[1]}
        )
        environment.notional.updateTokenCollateralParameters(
            currencyId, *(nTokenDefaults["Collateral"]), {"from": accounts[1]}
        )
        environment.notional.updateInterestRateCurve(
            currencyId, [1, 2], [get_interest_rate_curve()] * 2, {"from": accounts[1]}
        )

        cashGroup = list(environment.notional.getCashGroup(currencyId))
        environment.notional.updateCashGroup(currencyId, cashGroup, {"from": accounts[1]})
        environment.notional.updateAssetRate(10, zeroAddress, {"from": accounts[1]})
        environment.notional.updateETHRate(
            10, zeroAddress, True, 100, 100, 100, {"from": accounts[1]}
        )
        environment.notional.updateGlobalTransferOperator(
            accounts[1].address, True, {"from": accounts[1]}
        )

    with brownie.reverts("Unauthorized caller"):
        environment.notional.nTokenRedeem(
            accounts[2], 1, 100e8, False, False, {"from": accounts[1]}
        )
        environment.notional.batchBalanceAction(accounts[2], [], {"from": accounts[1]})
        environment.notional.batchBalanceAndTradeAction(accounts[2], [], {"from": accounts[1]})


def test_prevent_duplicate_token_listing(environment, accounts):
    symbol = "DAI"
    assert environment.notional.getCurrencyId(environment.token[symbol].address) == 2
    with brownie.reverts(dev_revert_msg="dev: duplicate listing"):
        environment.notional.listCurrency(
            (
                environment.token[symbol].address,
                symbol == "USDT",
                TokenType["UnderlyingToken"],
                18,
                0,
            ),
            (
                environment.ethOracle[symbol].address,
                0,
                False,
                CurrencyDefaults["buffer"],
                CurrencyDefaults["haircut"],
                CurrencyDefaults["liquidationDiscount"],
            ),
            PrimeCashCurve,
            environment.primeCashOracle['ETH'],
            True,
            12,
            'USDT',
            'Tether USD',
            {"from": accounts[0]},
        )

@given(useBitmap=strategy("bool"))
def test_max_tokens_revert(environment, accounts, useBitmap, MockERC20, UnderlyingHoldingsOracle):
    if useBitmap:
        environment.notional.enableBitmapCurrency(1, {"from": accounts[1]})

    for i in range(0, 10):
        erc20 = MockERC20.deploy("mock", "mock", 18, 0, {"from": accounts[1]})
        pCashOracle = UnderlyingHoldingsOracle.deploy(environment.notional.address, erc20.address, {"from": accounts[1]})

        erc20.transfer(environment.notional.address, 0.05e18, {"from": accounts[1]})
        txn = environment.notional.listCurrency(
            (
                erc20.address,
                False,
                TokenType["UnderlyingToken"],
                18,
                0,
            ),
            (
                environment.ethOracle['DAI'].address,
                0,
                False,
                109,
                92,
                108
            ),
            PrimeCashCurve,
            pCashOracle,
            True,
            12,
            'mock',
            'mock',
            {"from": accounts[0]},
        )
        currencyId = txn.events['ListCurrency']['newCurrencyId']

        erc20.approve(environment.notional.address, 2 ** 255, {"from": accounts[1]})
        if i == 9:
            with brownie.reverts():
                environment.notional.depositUnderlyingToken(accounts[1], currencyId, 1e18, {"from": accounts[1]})
        else:
            environment.notional.depositUnderlyingToken(accounts[1], currencyId, 1e18, {"from": accounts[1]})