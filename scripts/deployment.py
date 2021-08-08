from copy import copy

from brownie import (
    AccountAction,
    BatchAction,
    ERC1155Action,
    FreeCollateralExternal,
    GovernanceAction,
    GovernorAlpha,
    InitializeMarketsAction,
    LiquidateCurrencyAction,
    LiquidatefCashAction,
    MockAggregator,
    MockERC20,
    NoteERC20,
    PauseRouter,
    Router,
    SettleAssetsExternal,
    TradingAction,
    Views,
    accounts,
    cTokenAggregator,
    nCErc20,
    nCEther,
    nComptroller,
    nJumpRateModel,
    nPriceOracle,
    nProxy,
    nProxyAdmin,
    nTokenAction,
    nTokenERC20Proxy,
    nTokenMintAction,
    nTokenRedeemAction,
    nWhitePaperInterestRateModel,
)
from brownie.convert.datatypes import HexString
from brownie.network import web3
from brownie.network.contract import Contract
from brownie.network.state import Chain
from brownie.project import ContractsVProject
from scripts.config import CompoundConfig, CurrencyDefaults, GovernanceConfig, TokenConfig

chain = Chain()

TokenType = {"UnderlyingToken": 0, "cToken": 1, "cETH": 2, "Ether": 3, "NonMintable": 4}


def deployNoteERC20(deployer):
    # Deploy governance contracts
    noteERC20Implementation = NoteERC20.deploy({"from": deployer})
    # This is a proxied ERC20
    noteERC20Proxy = nProxy.deploy(noteERC20Implementation.address, bytes(), {"from": deployer})

    noteERC20 = Contract.from_abi("NoteERC20", noteERC20Proxy.address, abi=NoteERC20.abi)

    return (noteERC20Proxy, noteERC20)


def deployGovernance(deployer, noteERC20, guardian, governorConfig):
    return GovernorAlpha.deploy(
        governorConfig["quorumVotes"],
        governorConfig["proposalThreshold"],
        governorConfig["votingDelayBlocks"],
        governorConfig["votingPeriodBlocks"],
        noteERC20.address,
        guardian,
        governorConfig["minDelay"],
        {"from": deployer},
    )


def deployNotional(deployer, cETHAddress, guardianAddress):
    # Deploy Libraries
    SettleAssetsExternal.deploy({"from": deployer})
    FreeCollateralExternal.deploy({"from": deployer})
    TradingAction.deploy({"from": deployer})
    nTokenMintAction.deploy({"from": deployer})

    # Deploy logic contracts
    governance = GovernanceAction.deploy({"from": deployer})
    views = Views.deploy({"from": deployer})
    initializeMarkets = InitializeMarketsAction.deploy({"from": deployer})
    nTokenRedeem = nTokenRedeemAction.deploy({"from": deployer})
    nTokenAction_ = nTokenAction.deploy({"from": deployer})
    batchAction = BatchAction.deploy({"from": deployer})
    accountAction = AccountAction.deploy({"from": deployer})
    erc1155Action = ERC1155Action.deploy({"from": deployer})
    liquidateCurrencyAction = LiquidateCurrencyAction.deploy({"from": deployer})
    liquidatefCashAction = LiquidatefCashAction.deploy({"from": deployer})

    # Deploy Pause Router
    pauseRouter = PauseRouter.deploy(views.address, {"from": deployer})

    # Deploy router
    router = Router.deploy(
        governance.address,
        views.address,
        initializeMarkets.address,
        nTokenAction_.address,
        nTokenRedeem.address,
        batchAction.address,
        accountAction.address,
        erc1155Action.address,
        liquidateCurrencyAction.address,
        liquidatefCashAction.address,
        cETHAddress,
        {"from": deployer},
    )

    initializeData = web3.eth.contract(abi=Router.abi).encodeABI(
        fn_name="initialize", args=[deployer.address, pauseRouter.address, guardianAddress]
    )

    proxy = nProxy.deploy(
        router.address, initializeData, {"from": deployer}  # Deployer is set to owner
    )

    notionalInterfaceABI = ContractsVProject._build.get("NotionalProxy")["abi"]
    notional = Contract.from_abi(
        "Notional", proxy.address, abi=notionalInterfaceABI, owner=deployer
    )

    return (pauseRouter, router, proxy, notional)


class TestEnvironment:
    def __init__(self, deployer, withGovernance=False, multisig=None):
        self.deployer = deployer
        self.proxyAdmin = nProxyAdmin.deploy({"from": self.deployer})
        self.compPriceOracle = nPriceOracle.deploy({"from": deployer})
        self.comptroller = nComptroller.deploy({"from": deployer})
        self.comptroller._setMaxAssets(20)
        self.comptroller._setPriceOracle(self.compPriceOracle.address)
        self.currencyId = {}
        self.token = {}
        self.ethOracle = {}
        self.cToken = {}
        self.cTokenAggregator = {}
        self.nToken = {}
        self.router = {}
        self.multisig = multisig

        if withGovernance:
            self._deployGovernance()
        else:
            self._deployNoteERC20()

        # First deploy tokens to ensure they are available
        self._deployMockCurrency("ETH")
        for symbol in TokenConfig.keys():
            self._deployMockCurrency(symbol)

        self._deployNotional()

        if withGovernance:
            self.notional.transferOwnership(self.governor.address)
            self.proxyAdmin.transferOwnership(self.governor.address)
            self.noteERC20.initialize(
                [self.governor.address, self.multisig.address, self.notional.address],
                [
                    GovernanceConfig["initialBalances"]["DAO"],
                    GovernanceConfig["initialBalances"]["MULTISIG"],
                    GovernanceConfig["initialBalances"]["NOTIONAL"],
                ],
                self.deployer.address,
                {"from": self.deployer},
            )
            self.noteERC20.activateNotional(self.notional.address, {"from": self.deployer})
            self.noteERC20.transferOwnership(self.governor.address, {"from": self.deployer})
        else:
            self.noteERC20.initialize(
                [self.deployer, self.notional.address],
                [99_000_000e8, GovernanceConfig["initialBalances"]["NOTIONAL"]],
                self.deployer.address,
                {"from": self.deployer},
            )
            self.noteERC20.activateNotional(self.notional.address, {"from": self.deployer})

        self.startTime = chain.time()

    def _deployNoteERC20(self):
        (self.noteERC20Proxy, self.noteERC20) = deployNoteERC20(self.deployer)

    def _deployGovernance(self):
        self._deployNoteERC20()

        # This is not a proxy but can be upgraded by deploying a new contract and changing ownership
        self.governor = deployGovernance(
            self.deployer, self.noteERC20, self.multisig, GovernanceConfig["governorConfig"]
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
        self.comptroller._setCollateralFactor(
            cToken.address, 750000000000000000, {"from": self.deployer}
        )
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
            self._deployCToken("ETH", None, None)
        else:
            config = TokenConfig[symbol]
            token = MockERC20.deploy(
                config["name"], symbol, config["decimals"], config["fee"], {"from": self.deployer}
            )
            self.ethOracle[symbol] = MockAggregator.deploy(18, {"from": self.deployer})
            self.ethOracle[symbol].setAnswer(config["rate"])

            if symbol != "NOMINT":
                self._deployCToken(symbol, token, config["rate"])
            self.token[symbol] = token

    def _deployNotional(self):
        (self.pauseRouter, self.router, self.proxy, self.notional) = deployNotional(
            self.deployer, self.cToken["ETH"].address, accounts[8].address
        )
        self.enableCurrency("ETH", CurrencyDefaults)

    def enableCurrency(self, symbol, config):
        currencyId = 1
        if symbol == "NOMINT":
            zeroAddress = HexString(0, "bytes20")
            txn = self.notional.listCurrency(
                (self.token[symbol].address, symbol == "USDT", TokenType["NonMintable"]),
                (zeroAddress, False, 0),
                self.ethOracle[symbol].address,
                False,
                config["buffer"],
                config["haircut"],
                config["liquidationDiscount"],
            )
            currencyId = txn.events["ListCurrency"]["newCurrencyId"]

        elif symbol != "ETH":
            txn = self.notional.listCurrency(
                (self.cToken[symbol].address, symbol == "USDT", TokenType["cToken"]),
                (self.token[symbol].address, symbol == "USDT", TokenType["UnderlyingToken"]),
                self.ethOracle[symbol].address,
                False,
                config["buffer"],
                config["haircut"],
                config["liquidationDiscount"],
            )
            currencyId = txn.events["ListCurrency"]["newCurrencyId"]

        if symbol == "NOMINT":
            assetRateAddress = HexString(0, "bytes20")
        else:
            assetRateAddress = self.cTokenAggregator[symbol].address

        self.notional.enableCashGroup(
            currencyId,
            assetRateAddress,
            (
                config["maxMarketIndex"],
                config["rateOracleTimeWindow"],
                config["totalFee"],
                config["reserveFeeShare"],
                config["debtBuffer"],
                config["fCashHaircut"],
                config["settlementPenalty"],
                config["liquidationfCashDiscount"],
                config["liquidationDebtBuffer"],
                config["tokenHaircut"][0 : config["maxMarketIndex"]],
                config["rateScalar"][0 : config["maxMarketIndex"]],
            ),
            self.token[symbol].name() if symbol != "ETH" else "Ether",
            symbol,
        )

        self.currencyId[symbol] = currencyId
        nTokenAddress = self.notional.nTokenAddress(currencyId)
        self.nToken[currencyId] = Contract.from_abi(
            "nToken", nTokenAddress, abi=nTokenERC20Proxy.abi, owner=self.deployer
        )


def main():
    env = TestEnvironment(accounts[0])
    for symbol in TokenConfig.keys():
        config = copy(CurrencyDefaults)
        if symbol == "USDT":
            config["haircut"] = 0

        env.enableCurrency(symbol, config)

    return env
