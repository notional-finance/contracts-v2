from brownie import (
    Governance,
    GovernorAlpha,
    InitializeMarketsAction,
    MockAggregator,
    MockERC20,
    MockWETH,
    NoteERC20,
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


def deployCToken(name, underlyingToken, comptroller, deployer, rate, compPriceOracle):
    cToken = None

    if name == "eth":
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

    if name == "wbtc":
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

    if name == "dai":
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

    if name == "usdc":
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

    if name == "tether":
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

    comptroller._supportMarket(cToken.address, {"from": deployer})
    if name != "eth":
        compPriceOracle.setUnderlyingPrice(cToken.address, rate)

    return (cToken, cTokenAggregator.deploy(cToken.address, {"from": deployer}))


def deployMockCompound(deployer):
    compPriceOracle = nPriceOracle.deploy({"from": deployer})
    comptroller = nComptroller.deploy({"from": deployer})
    comptroller._setPriceOracle(compPriceOracle.address)

    return (comptroller, compPriceOracle)


def deployMockCurrencies(deployer, comptroller, compPriceOracle):
    # This is required to initialize ETH
    weth = MockWETH.deploy({"from": deployer})
    (cETH, cETHAdapter) = deployCToken("eth", None, comptroller, deployer, None, None)

    dai = MockERC20.deploy("Dai Stablecoin", "DAI", 18, 0, {"from": deployer})
    daiETHOracle = MockAggregator.deploy(18, {"from": deployer})
    daiETHOracle.setAnswer(0.01e18)
    # TODO: can we just deploy a single adapter or put this into the base contracts?
    (cDAI, cDAIAdapter) = deployCToken("dai", dai, comptroller, deployer, 0.01e18, compPriceOracle)

    usdc = MockERC20.deploy("USD Coin", "USDC", 6, 0, {"from": deployer})
    usdcETHOracle = MockAggregator.deploy(18, {"from": deployer})
    usdcETHOracle.setAnswer(0.01e18)
    (cUSDC, cUSDCAdapter) = deployCToken(
        "usdc", usdc, comptroller, deployer, 0.01e18, compPriceOracle
    )

    tether = MockERC20.deploy("Tether USD", "USDT", 6, 0.001e18, {"from": deployer})
    tetherETHOracle = MockAggregator.deploy(18, {"from": deployer})
    tetherETHOracle.setAnswer(0.01e18)
    (cUSDT, cUSDTAdapter) = deployCToken(
        "tether", tether, comptroller, deployer, 0.01e18, compPriceOracle
    )

    wbtc = MockERC20.deploy("Wrapped BTC", "WBTC", 8, 0, {"from": deployer})
    wbtcETHOracle = MockAggregator.deploy(18, {"from": deployer})
    wbtcETHOracle.setAnswer(100e18)
    (cWBTC, cWBTCAdapter) = deployCToken(
        "wbtc", wbtc, comptroller, deployer, 100e18, compPriceOracle
    )

    return {
        "weth": (weth, None, cETH, cETHAdapter),
        "dai": (dai, daiETHOracle, cDAI, cDAIAdapter),
        "usdc": (usdc, usdcETHOracle, cUSDC, cUSDCAdapter),
        "tether": (tether, tetherETHOracle, cUSDT, cUSDTAdapter),
        "wbtc": (wbtc, wbtcETHOracle, cWBTC, cWBTCAdapter),
    }


def list_currencies(mockCurrencies, proxy, deployer):
    governance = Contract.from_abi("Governance", proxy.address, abi=Governance.abi, owner=deployer)
    currencyId = 1
    for (name, (underlying, ethRateOracle, asset, adapter)) in mockCurrencies.items():
        if name != "weth":
            governance.listCurrency(
                asset.address,
                name == "tether",  # hasFee
                ethRateOracle.address,
                False,
                140,
                0 if name == "tether" else 100,
                105,
            )

        governance.enableCashGroup(
            currencyId,
            adapter.address,
            adapter.address,  # TODO: update this
            (
                2,  # max market index
                20,  # rate oracle time window
                30,  # liquidity fee
                95,  # token haircut
                30,  # debt buffer
                30,  # fcash haircut
                100,  # rate scalar
            ),
        )

        currencyId += 1


def main():
    deployer = accounts[0]
    (comptroller, compPriceOracle) = deployMockCompound(deployer)
    mockCurrencies = deployMockCurrencies(deployer, comptroller, compPriceOracle)

    # Deploy logic contracts
    governance = Governance.deploy({"from": deployer})
    views = Views.deploy({"from": deployer})
    initialize = InitializeMarketsAction.deploy({"from": deployer})

    # Deploy router
    router = Router.deploy(
        governance.address,
        views.address,
        initialize.address,
        mockCurrencies["weth"][2].address,  # cETH
        mockCurrencies["weth"][0].address,  # WETH
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

    list_currencies(mockCurrencies, proxy, deployer)
    print("Proxy Address: ", proxy.address)

    # Enable governance:
    # (noteERC20, timelock, governor) = deployGovernance(proxyAdmin, deployer, deployer)
