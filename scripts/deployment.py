from copy import copy

from brownie import (
    DepositWithdrawAction,
    FreeCollateralExternal,
    GovernanceAction,
    GovernorAlpha,
    InitializeMarketsAction,
    MintPerpetualTokenAction,
    MockAggregator,
    MockERC20,
    NoteERC20,
    PerpetualTokenAction,
    PerpetualTokenERC20,
    RedeemPerpetualTokenAction,
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
    nProxyAdmin,
    nTransparentUpgradeableProxy,
    nWhitePaperInterestRateModel,
)
from brownie.network import web3
from brownie.network.contract import Contract
from brownie.network.state import Chain
from brownie.project import ContractsVProject
from scripts.config import CompoundConfig, CurrencyDefaults, GovernanceConfig, TokenConfig

chain = Chain()

TokenType = {"UnderlyingToken": 0, "cToken": 1, "cETH": 2, "NonMintable": 3}


class TestEnvironment:
    def __init__(self, deployer, withGovernance=False, multisig=None):
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
        self.multisig = multisig

        if withGovernance:
            self._deployGovernance()
        else:
            self._deployNoteERC20()

        self._deployNotional()

        if withGovernance:
            self.notional.transferOwnership(self.governor.address)
            self.noteERC20.transfer(
                self.governor.address,
                GovernanceConfig["initialBalances"]["DAO"],
                {"from": self.deployer},
            )
            self.noteERC20.transfer(
                self.multisig.address,
                GovernanceConfig["initialBalances"]["MULTISIG"],
                {"from": self.deployer},
            )

        # Transfer some initial supply for minting
        self.noteERC20.transfer(self.proxy.address, 1000000e8, {"from": self.deployer})

        self.startTime = chain.time()

    def _deployNoteERC20(self):
        # Deploy governance contracts
        noteERC20Implementation = NoteERC20.deploy({"from": self.deployer})
        # This is a proxied ERC20
        initializeData = web3.eth.contract(abi=NoteERC20.abi).encodeABI(
            fn_name="initialize", args=[self.deployer.address]
        )

        self.noteERC20Proxy = nTransparentUpgradeableProxy.deploy(
            noteERC20Implementation.address,
            self.proxyAdmin.address,
            initializeData,
            {"from": self.deployer},
        )

        self.noteERC20 = Contract.from_abi(
            "NoteERC20", self.noteERC20Proxy.address, abi=NoteERC20.abi
        )

    def _deployGovernance(self):
        self._deployNoteERC20()

        # This is not a proxy but can be upgraded by deploying a new contract and changing ownership
        self.governor = GovernorAlpha.deploy(
            GovernanceConfig["governorConfig"]["quorumVotes"],
            GovernanceConfig["governorConfig"]["proposalThreshold"],
            GovernanceConfig["governorConfig"]["votingDelayBlocks"],
            GovernanceConfig["governorConfig"]["votingPeriodBlocks"],
            self.noteERC20.address,
            self.multisig,
            GovernanceConfig["governorConfig"]["minDelay"],
            {"from": self.deployer},
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

        # Deploy Libraries
        FreeCollateralExternal.deploy({"from": self.deployer})
        SettleAssetsExternal.deploy({"from": self.deployer})
        TradingAction.deploy({"from": self.deployer})
        MintPerpetualTokenAction.deploy({"from": self.deployer})

        # Deploy logic contracts
        governance = GovernanceAction.deploy({"from": self.deployer})
        views = Views.deploy({"from": self.deployer})
        initializeMarkets = InitializeMarketsAction.deploy({"from": self.deployer})
        perpetualTokenRedeem = RedeemPerpetualTokenAction.deploy({"from": self.deployer})
        perpetualTokenAction = PerpetualTokenAction.deploy({"from": self.deployer})
        depositWithdrawAction = DepositWithdrawAction.deploy({"from": self.deployer})

        # Deploy router
        router = Router.deploy(
            governance.address,
            views.address,
            initializeMarkets.address,
            perpetualTokenAction.address,
            perpetualTokenRedeem.address,
            depositWithdrawAction.address,
            self.cToken["ETH"].address,
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

        notionalInterfaceABI = ContractsVProject._build.get("NotionalProxy")["abi"]
        self.notional = Contract.from_abi(
            "Notional", self.proxy.address, abi=notionalInterfaceABI, owner=self.deployer
        )
        self.enableCurrency("ETH", CurrencyDefaults)

    def enableCurrency(self, symbol, config):
        currencyId = 1
        if symbol != "ETH":
            self._deployMockCurrency(symbol)

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

        self.notional.enableCashGroup(
            currencyId,
            self.cTokenAggregator[symbol].address,
            (
                config["maxMarketIndex"],
                config["rateOracleTimeWindow"],
                config["totalFee"],
                config["reserveFeeShare"],
                config["debtBuffer"],
                config["fCashHaircut"],
                config["settlementPenalty"],
                config["liquidityRepoDiscount"],
                config["tokenHaircut"][0 : config["maxMarketIndex"]],
                config["rateScalar"][0 : config["maxMarketIndex"]],
            ),
        )

        self.currencyId[symbol] = currencyId
        perpTokenAddress = self.notional.getPerpetualTokenAddress(currencyId)
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
