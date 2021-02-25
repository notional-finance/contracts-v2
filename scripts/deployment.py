from copy import copy

from brownie import (
    GovernanceAction,
    GovernorAlpha,
    InitializeMarketsAction,
    MintPerpetualTokenAction,
    MockAggregator,
    MockERC20,
    MockWETH,
    NoteERC20,
    PerpetualTokenAction,
    Router,
    Views,
    accounts,
    cTokenAggregator,
    nCErc20,
    nCEther,
    nComptroller,
    nJumpRateModel,
    nPriceOracle,
    nProxyAdmin,
    nTimelockController,
    nTransparentUpgradeableProxy,
    nWhitePaperInterestRateModel,
)
from brownie.network import web3
from brownie.network.contract import Contract
from scripts.config import CurrencyDefaults, TokenConfig


def deployGovernance(proxyAdmin, notionalProxy, deployer):
    # Deploy governance contracts
    noteERC20 = NoteERC20.deploy({"from": deployer})
    # This is a proxied ERC20
    initializeData = web3.eth.contract(abi=NoteERC20.abi).encodeABI(
        fn_name="initialize", args=[deployer.address]
    )
    noteERC20Proxy = nTransparentUpgradeableProxy.deploy(
        noteERC20.address, proxyAdmin.address, initializeData, {"from": deployer}
    )

    timelock = nTimelockController.deploy(
        1, [], [], {"from": deployer}  # minDelay is in seconds  # Proposers  # Executors
    )

    governor = GovernorAlpha.deploy(
        timelock.address, noteERC20.address, deployer, {"from": deployer}  # Guardian address
    )

    timelock.grantRole(timelock.TIMELOCK_ADMIN_ROLE(), governor.address, {"from": deployer})
    timelock.grantRole(timelock.PROPOSER_ROLE(), governor.address, {"from": deployer})
    timelock.grantRole(timelock.EXECUTOR_ROLE(), governor.address, {"from": deployer})
    timelock.renounceRole(timelock.TIMELOCK_ADMIN_ROLE(), deployer.address, {"from": deployer})

    return (noteERC20Proxy, timelock, governor)


def deployCToken(symbol, underlyingToken, comptroller, deployer, rate, compPriceOracle):
    cToken = None

    if symbol == "ETH":
        # cETH uses whitepaper interest rate model
        # cETH: https://etherscan.io/address/0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5
        # Interest Rate Model:
        # https://etherscan.io/address/0x0c3f8df27e1a00b47653fde878d68d35f00714c0
        initialExchangeRate = 200000000000000000000000000
        interestRateModel = nWhitePaperInterestRateModel.deploy(
            20000000000000000, 100000000000000000, {"from": deployer}  # Base Rate  # Multiplier
        )

        cToken = nCEther.deploy(
            comptroller.address,
            interestRateModel.address,
            initialExchangeRate,
            "Compound Ether",
            "cETH",
            8,
            deployer.address,
            {"from": deployer},
        )

    elif symbol == "WBTC":
        # cWBTC uses whitepaper interest rate model
        # cWBTC https://etherscan.io/address/0xc11b1268c1a384e55c48c2391d8d480264a3a7f4
        # Interest Rate Model:
        # https://etherscan.io/address/0xbae04cbf96391086dc643e842b517734e214d698#code
        initialExchangeRate = 20000000000000000
        interestRateModel = nWhitePaperInterestRateModel.deploy(
            20000000000000000, 300000000000000000, {"from": deployer}  # Base Rate  # Multiplier
        )

        cToken = nCErc20.deploy(
            underlyingToken.address,
            comptroller.address,
            interestRateModel.address,
            initialExchangeRate,
            "Compound Wrapped BTC",
            "cWBTC",
            8,
            deployer.address,
            {"from": deployer},
        )

    elif symbol == "DAI":
        # cDai: https://etherscan.io/address/0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643
        # Jump interest rate model:
        # https://etherscan.io/address/0xfb564da37b41b2f6b6edcc3e56fbf523bd9f2012
        initialExchangeRate = 200000000000000000000000000
        interestRateModel = nJumpRateModel.deploy(
            0,  # Base Rate
            40000000000000000,  # Multiplier
            1090000000000000000,  # Jump multiplier per year
            800000000000000000,  # kink
            {"from": deployer},
        )

        cToken = nCErc20.deploy(
            underlyingToken.address,
            comptroller.address,
            interestRateModel.address,
            initialExchangeRate,
            "Compound Dai",
            "cDAI",
            8,
            deployer.address,
            {"from": deployer},
        )

    elif symbol == "USDC":
        # cUSDC: https://etherscan.io/address/0x39aa39c021dfbae8fac545936693ac917d5e7563
        # Jump interest rate model:
        # https://etherscan.io/address/0xd8ec56013ea119e7181d231e5048f90fbbe753c0
        initialExchangeRate = 200000000000000
        interestRateModel = nJumpRateModel.deploy(
            0,  # Base Rate
            40000000000000000,  # Multiplier
            1090000000000000000,  # Jump multiplier per year
            800000000000000000,  # kink
            {"from": deployer},
        )

        cToken = nCErc20.deploy(
            underlyingToken.address,
            comptroller.address,
            interestRateModel.address,
            initialExchangeRate,
            "Compound USDC",
            "cUSDC",
            8,
            deployer.address,
            {"from": deployer},
        )

    elif symbol == "USDT":
        # cTether: https://etherscan.io/address/0xf650c3d88d12db855b8bf7d11be6c55a4e07dcc9
        # Jump Rate mode: https://etherscan.io/address/0xfb564da37b41b2f6b6edcc3e56fbf523bd9f2012
        initialExchangeRate = 200000000000000
        interestRateModel = nJumpRateModel.deploy(
            0,  # Base Rate
            40000000000000000,  # Multiplier
            1090000000000000000,  # Jump multiplier per year
            800000000000000000,  # kink
            {"from": deployer},
        )

        cToken = nCErc20.deploy(
            underlyingToken.address,
            comptroller.address,
            interestRateModel.address,
            initialExchangeRate,
            "Compound USDT",
            "cUSDT",
            8,
            deployer.address,
            {"from": deployer},
        )

    else:
        raise Exception("Unknown currency {}".format(symbol))

    comptroller._supportMarket(cToken.address, {"from": deployer})
    if symbol != "ETH":
        compPriceOracle.setUnderlyingPrice(cToken.address, rate)

    return (cToken, cTokenAggregator.deploy(cToken.address, {"from": deployer}))


def deployMockCompound(deployer):
    compPriceOracle = nPriceOracle.deploy({"from": deployer})
    comptroller = nComptroller.deploy({"from": deployer})
    comptroller._setPriceOracle(compPriceOracle.address)

    return (comptroller, compPriceOracle)


def deployMockCurrency(deployer, comptroller, compPriceOracle, symbol):
    if symbol == "ETH":
        # This is required to initialize ETH
        weth = MockWETH.deploy({"from": deployer})
        (cToken, cAdapter) = deployCToken("ETH", None, comptroller, deployer, None, None)

        return (weth, None, cToken, cAdapter)
    else:
        config = TokenConfig[symbol]
        token = MockERC20.deploy(
            config["name"], symbol, config["decimals"], config["fee"], {"from": deployer}
        )
        ethOracle = MockAggregator.deploy(18, {"from": deployer})
        ethOracle.setAnswer(config["rate"])
        (cToken, cTokenAdapter) = deployCToken(
            symbol, token, comptroller, deployer, config["rate"], compPriceOracle
        )

        # TODO: can we simplify the deployment of cTokenAdapter to one overall?
        return (token, ethOracle, cToken, cTokenAdapter)


def deployNotional(deployer, comptroller, compPriceOracle):
    # This must be deployed to enable Notional
    (WETH, _, cETH, cETHAdapter) = deployMockCurrency(deployer, comptroller, compPriceOracle, "ETH")

    # Deploy logic contracts
    governance = GovernanceAction.deploy({"from": deployer})
    views = Views.deploy({"from": deployer})
    initialize = InitializeMarketsAction.deploy({"from": deployer})
    perpetualTokenMint = MintPerpetualTokenAction.deploy({"from": deployer})
    perpetualTokenAction = PerpetualTokenAction.deploy({"from": deployer})

    # Deploy router
    router = Router.deploy(
        governance.address,
        views.address,
        initialize.address,
        perpetualTokenAction.address,
        perpetualTokenMint.address,
        cETH.address,  # cETH
        WETH.address,  # WETH
        {"from": deployer},
    )

    proxyAdmin = nProxyAdmin.deploy({"from": deployer})
    initializeData = web3.eth.contract(abi=Router.abi).encodeABI(
        fn_name="initialize", args=[deployer.address]
    )

    proxy = nTransparentUpgradeableProxy.deploy(
        router.address,
        proxyAdmin.address,
        initializeData,  # Deployer is set to owner
        {"from": deployer},
    )

    enableCurrency(
        deployer, proxy, comptroller, compPriceOracle, "ETH", CurrencyDefaults, cETHAdapter
    )

    return proxy


def enableCurrency(
    deployer, proxy, comptroller, compPriceOracle, symbol, config, cTokenAdapter=None
):
    governance = Contract.from_abi(
        "Governance", proxy.address, abi=GovernanceAction.abi, owner=deployer
    )

    currencyId = 1
    if symbol != "ETH":
        (token, ethRateOracle, cToken, cTokenAdapter) = deployMockCurrency(
            deployer, comptroller, compPriceOracle, symbol
        )

        txn = governance.listCurrency(
            cToken.address,
            symbol == "USDT",  # hasFee
            ethRateOracle.address,
            False,
            config["buffer"],
            config["haircut"],
            config["liquidationDiscount"],
        )
        currencyId = txn.events["ListCurrency"]["newCurrencyId"]

    governance.enableCashGroup(
        currencyId,
        cTokenAdapter.address,
        (
            config["maxMarketIndex"],
            config["rateOracleTimeWindow"],
            config["liquidityFee"],
            config["tokenHaircut"],
            config["debtBuffer"],
            config["fCashHaircut"],
            config["rateScalar"],
        ),
    )

    return currencyId


def main():
    deployer = accounts[0]
    (comptroller, compPriceOracle) = deployMockCompound(deployer)
    proxy = deployNotional(deployer, comptroller, compPriceOracle)

    for symbol in TokenConfig.keys():
        config = copy(CurrencyDefaults)
        if symbol == "USDT":
            config["haircut"] = 0

        enableCurrency(deployer, proxy, comptroller, compPriceOracle, symbol, config)

    print("Proxy Address: ", proxy.address)

    # Enable governance:
    # (noteERC20, timelock, governor) = deployGovernance(proxyAdmin, deployer, deployer)
