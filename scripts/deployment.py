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
    PerpetualTokenERC20,
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
from brownie.network.state import Chain
from scripts.config import CompoundConfig, CurrencyDefaults, TokenConfig

chain = Chain()


class TestEnvironment:
    def __init__(self, deployer):
        self.deployer = deployer
        self.proxyAdmin = nProxyAdmin.deploy({"from": self.deployer})
        self.compPriceOracle = nPriceOracle.deploy({"from": deployer})
        self.comptroller = nComptroller.deploy({"from": deployer})
        self.comptroller._setPriceOracle(self.compPriceOracle.address)
        self.currencyId = {}
        self.token = {}
        self.ethOracle = {}
        self.cToken = {}
        self.cTokenAggregator = {}
        self.perpToken = {}
        self.router = {}

        self._deployNotional()
        self.startTime = chain.time()

    def _deployGovernance(self):
        # Deploy governance contracts
        noteERC20 = NoteERC20.deploy({"from": self.deployer})
        # This is a proxied ERC20
        initializeData = web3.eth.contract(abi=NoteERC20.abi).encodeABI(
            fn_name="initialize", args=[self.deployer.address]
        )
        self.noteERC20Proxy = nTransparentUpgradeableProxy.deploy(
            noteERC20.address, self.proxyAdmin.address, initializeData, {"from": self.deployer}
        )

        self.timelock = nTimelockController.deploy(
            1, [], [], {"from": self.deployer}  # minDelay is in seconds  # Proposers  # Executors
        )

        self.governor = GovernorAlpha.deploy(
            self.timelock.address,
            self.noteERC20.address,
            self.deployer,
            {"from": self.deployer},  # Guardian address
        )

        self.timelock.grantRole(
            self.timelock.TIMELOCK_ADMIN_ROLE(), self.governor.address, {"from": self.deployer}
        )
        self.timelock.grantRole(
            self.timelock.PROPOSER_ROLE(), self.governor.address, {"from": self.deployer}
        )
        self.timelock.grantRole(
            self.timelock.EXECUTOR_ROLE(), self.governor.address, {"from": self.deployer}
        )
        self.timelock.renounceRole(
            self.timelock.TIMELOCK_ADMIN_ROLE(), self.deployer.address, {"from": self.deployer}
        )

    def _deployCToken(self, symbol, underlyingToken, rate):
        cToken = None
        config = CompoundConfig[symbol]
        # Deploy interest rate model
        interestRateModel = None
        if config["interestRateModel"]["name"] == "whitepaper":
            interestRateModel = nWhitePaperInterestRateModel.deploy(
                config["interestRateModel"]["baseRate"],
                config["interestRateModel"]["multiplier"],
                {"from": self.deployer},
            )
        elif config["interestRateModel"]["name"] == "jump":
            interestRateModel = nJumpRateModel.deploy(
                config["interestRateModel"]["baseRate"],
                config["interestRateModel"]["multiplier"],
                config["interestRateModel"]["jumpMultiplierPerYear"],
                config["interestRateModel"]["kink"],
                {"from": self.deployer},
            )

        if symbol == "ETH":
            cToken = nCEther.deploy(
                self.comptroller.address,
                interestRateModel.address,
                config["initialExchangeRate"],
                "Compound Ether",
                "cETH",
                8,
                self.deployer.address,
                {"from": self.deployer},
            )
        else:
            cToken = nCErc20.deploy(
                underlyingToken.address,
                self.comptroller.address,
                interestRateModel.address,
                config["initialExchangeRate"],
                "Compound " + symbol,  # This is not exactly correct but whatever
                "c" + symbol,
                8,
                self.deployer.address,
                {"from": self.deployer},
            )

        self.comptroller._supportMarket(cToken.address, {"from": self.deployer})
        if symbol != "ETH":
            self.compPriceOracle.setUnderlyingPrice(cToken.address, rate)

        self.cToken[symbol] = cToken
        # TODO: can we simplify the deployment of cTokenAggregator to one overall?
        self.cTokenAggregator[symbol] = cTokenAggregator.deploy(
            cToken.address, {"from": self.deployer}
        )

    def _deployMockCurrency(self, symbol):
        if symbol == "ETH":
            # This is required to initialize ETH
            self.token["ETH"] = MockWETH.deploy({"from": self.deployer})
            self._deployCToken("ETH", None, None)
        else:
            config = TokenConfig[symbol]
            token = MockERC20.deploy(
                config["name"], symbol, config["decimals"], config["fee"], {"from": self.deployer}
            )
            self.ethOracle[symbol] = MockAggregator.deploy(18, {"from": self.deployer})
            self.ethOracle[symbol].setAnswer(config["rate"])
            self._deployCToken(symbol, token, config["rate"])
            self.token[symbol] = token

    def _deployNotional(self):
        # This must be deployed to enable Notional
        self._deployMockCurrency("ETH")

        # Deploy logic contracts
        governance = GovernanceAction.deploy({"from": self.deployer})
        views = Views.deploy({"from": self.deployer})
        initialize = InitializeMarketsAction.deploy({"from": self.deployer})
        perpetualTokenMint = MintPerpetualTokenAction.deploy({"from": self.deployer})
        perpetualTokenAction = PerpetualTokenAction.deploy({"from": self.deployer})

        # Deploy router
        router = Router.deploy(
            governance.address,
            views.address,
            initialize.address,
            perpetualTokenAction.address,
            perpetualTokenMint.address,
            self.cToken["ETH"].address,
            self.token["ETH"].address,
            {"from": self.deployer},
        )

        initializeData = web3.eth.contract(abi=Router.abi).encodeABI(
            fn_name="initialize", args=[self.deployer.address]
        )

        self.proxy = nTransparentUpgradeableProxy.deploy(
            router.address,
            self.proxyAdmin.address,
            initializeData,  # Deployer is set to owner
            {"from": self.deployer},
        )

        # TODO: brownie doesn't allow bringing in interface for the abi
        self.router["Views"] = Contract.from_abi(
            "Views", self.proxy.address, abi=Views.abi, owner=self.deployer
        )
        self.router["MintPerpetual"] = Contract.from_abi(
            "MintPerpetual",
            self.proxy.address,
            abi=MintPerpetualTokenAction.abi,
            owner=self.deployer,
        )
        self.router["PerpetualAction"] = Contract.from_abi(
            "PerpetualAction", self.proxy.address, abi=PerpetualTokenAction.abi, owner=self.deployer
        )
        self.router["InitializeMarkets"] = Contract.from_abi(
            "InitializeMarkets",
            self.proxy.address,
            abi=InitializeMarketsAction.abi,
            owner=self.deployer,
        )
        # TODO: events aren't being parse out properly unless this is at the end
        self.router["Governance"] = Contract.from_abi(
            "Governance", self.proxy.address, abi=GovernanceAction.abi, owner=self.deployer
        )

        self.enableCurrency("ETH", CurrencyDefaults)

    def enableCurrency(self, symbol, config):
        currencyId = 1
        if symbol != "ETH":
            self._deployMockCurrency(symbol)

            txn = self.router["Governance"].listCurrency(
                self.cToken[symbol].address,
                symbol == "USDT",  # hasFee
                self.ethOracle[symbol].address,
                False,
                config["buffer"],
                config["haircut"],
                config["liquidationDiscount"],
            )
            currencyId = txn.events["ListCurrency"]["newCurrencyId"]

        self.router["Governance"].enableCashGroup(
            currencyId,
            self.cTokenAggregator[symbol].address,
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

        self.currencyId[symbol] = currencyId
        perpTokenAddress = self.router["Views"].getPerpetualTokenAddress(currencyId)
        self.perpToken[currencyId] = Contract.from_abi(
            "PerpetualToken", perpTokenAddress, abi=PerpetualTokenERC20.abi, owner=self.deployer
        )


def main():
    env = TestEnvironment(accounts[0])
    for symbol in TokenConfig.keys():
        config = copy(CurrencyDefaults)
        if symbol == "USDT":
            config["haircut"] = 0

        env.enableCurrency(symbol, config)

    return env
