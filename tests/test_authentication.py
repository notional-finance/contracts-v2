import brownie
import pytest
from brownie.convert.datatypes import HexString
from brownie.network.contract import Contract
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, nTokenDefaults
from scripts.deployment import TokenType, deployNotionalContracts
from tests.helpers import initialize_environment

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
                CurrencyDefaults["totalFee"],
                CurrencyDefaults["reserveFeeShare"],
                CurrencyDefaults["debtBuffer"],
                CurrencyDefaults["fCashHaircut"],
                CurrencyDefaults["settlementPenalty"],
                CurrencyDefaults["liquidationfCashDiscount"],
                CurrencyDefaults["tokenHaircut"][0 : CurrencyDefaults["maxMarketIndex"]],
                CurrencyDefaults["rateScalar"][0 : CurrencyDefaults["maxMarketIndex"]],
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
            currencyId, [0.01e9, 0.021e9, 0.07e9], [0.5e9, 0.5e9, 0.5e9], {"from": accounts[1]}
        )
        environment.notional.updateIncentiveEmissionRate(
            currencyId, CurrencyDefaults["incentiveEmissionRate"], {"from": accounts[1]}
        )
        environment.notional.updateTokenCollateralParameters(
            currencyId, *(nTokenDefaults["Collateral"]), {"from": accounts[1]}
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

    # Test nToken Proxy Authorization
    with brownie.reverts("Unauthorized caller"):
        environment.notional.nTokenTransferApprove(
            1, accounts[2], accounts[1], 2 ** 255, {"from": accounts[1]}
        )
        environment.notional.nTokenTransfer(
            1, accounts[2], accounts[1], 100e8, {"from": accounts[1]}
        )
        environment.notional.nTokenTransferFrom(
            1, accounts[2], accounts[1], accounts[0], 100e8, {"from": accounts[1]}
        )
        environment.notional.nTokenRedeemViaProxy(
            1, 100e8, accounts[1], accounts[1], {"from": accounts[1]}
        )
        environment.notional.nTokenMintViaProxy(1, 100e8, accounts[1], {"from": accounts[1]})


def test_prevent_duplicate_token_listing(environment, accounts):
    symbol = "DAI"
    assert environment.notional.getCurrencyId(environment.cToken[symbol].address) == 2
    with brownie.reverts("G: duplicate token listing"):
        environment.notional.listCurrency(
            (environment.cToken[symbol].address, symbol == "USDT", TokenType["cToken"], 8, 0),
            (
                environment.token[symbol].address,
                symbol == "USDT",
                TokenType["UnderlyingToken"],
                18,
                0,
            ),
            environment.ethOracle[symbol].address,
            False,
            CurrencyDefaults["buffer"],
            CurrencyDefaults["haircut"],
            CurrencyDefaults["liquidationDiscount"],
            {"from": accounts[0]},
        )
