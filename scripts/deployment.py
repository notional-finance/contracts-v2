import json
from copy import copy

import pytest
from brownie import (
    AccountAction,
    BatchAction,
    CalculationViews,
    ERC1155Action,
    FreeCollateralExternal,
    GovernanceAction,
    GovernorAlpha,
    InitializeMarketsAction,
    LiquidateCurrencyAction,
    LiquidatefCashAction,
    MigrateIncentives,
    MockAggregator,
    CompoundV2HoldingsOracle,
    MockERC20,
    MockWETH,
    NoteERC20,
    PauseRouter,
    Router,
    SettleAssetsExternal,
    TradingAction,
    TreasuryAction,
    VaultAccountAction,
    VaultAccountHealth,
    VaultAction,
    VaultLiquidationAction,
    Views,
    accounts,
    cTokenV2Aggregator,
    network,
    nProxy,
    nProxyAdmin,
    nTokenAction,
    nTokenERC20Proxy,
    nTokenMintAction,
    nTokenRedeemAction,
    PrimeCashProxy,
    PrimeDebtProxy,
    UpgradeableBeaconFactory
)
from brownie.convert.datatypes import HexString
from brownie.network import Rpc, web3
from brownie.network.contract import Contract
from brownie.network.state import Chain
from brownie.project import ContractsV2Project
from scripts.config import (
    CompoundConfig,
    CurrencyDefaults,
    GovernanceConfig,
    PrimeCashCurve,
    TokenConfig,
)
from tests.constants import ZERO_ADDRESS

chain = Chain()
rpc = Rpc()

TokenType = {
    "UnderlyingToken": 0,
    "cToken": 1,
    "cETH": 2,
    "Ether": 3,
    "NonMintable": 4,
    "aToken": 5,
}
zeroAddress = HexString(0, type_str="bytes20")


def deployNoteERC20(deployer):
    # These two lines ensure that the note token is deployed to the correct address
    # every time.
    if network.show_active() == "sandbox":
        deployer = accounts.load("DEVELOPMENT_DEPLOYER")
        accounts[0].transfer(deployer, 100e18)
    elif network.show_active() == "development" or network.show_active() == "hardhat":
        deployer = "0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3"

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
        0,
        {"from": deployer},
    )

def deployBeacons(deployer, proxy):
    factoryDeployer = "0x284CbC48848F8eB19c9aF5A3750059D22f148739"
    deployer.transfer(factoryDeployer, 1e18)

    # NOTE: the contract address still depends on the impl address
    nTokenImpl = nTokenERC20Proxy.deploy(proxy.address, {"from": factoryDeployer})
    pCashImpl = PrimeCashProxy.deploy(proxy.address, {"from": factoryDeployer})
    pDebtImpl = PrimeDebtProxy.deploy(proxy.address, {"from": factoryDeployer})
    factory = UpgradeableBeaconFactory.deploy({"from": factoryDeployer})

    nTokenBeacon = factory.deployBeacon(proxy, nTokenImpl, 1).return_value
    pCashBeacon = factory.deployBeacon(proxy, pCashImpl, 2).return_value
    pDebtBeacon = factory.deployBeacon(proxy, pDebtImpl, 3).return_value
    print("factory: ", factory.address)
    print("nToken: ", nTokenBeacon)
    print("pCash: ", pCashBeacon)
    print("pDebt: ", pDebtBeacon)

    # NOTE: in testing these beacon addresses are hardcoded in Deployments.sol
    return (nTokenBeacon, pCashBeacon, pDebtBeacon)

def deployNotionalContracts(deployer, **kwargs):
    contracts = {}
    if network.show_active() in ["goerli", "mainnet"]:
        raise Exception("update governance deployment!")

    # Deploy Libraries
    contracts["SettleAssetsExternal"] = SettleAssetsExternal.deploy({"from": deployer})
    contracts["FreeCollateralExternal"] = FreeCollateralExternal.deploy({"from": deployer})
    contracts["TradingAction"] = TradingAction.deploy({"from": deployer})
    contracts["nTokenMintAction"] = nTokenMintAction.deploy({"from": deployer})
    contracts["nTokenRedeemAction"] = nTokenRedeemAction.deploy({"from": deployer})
    contracts["MigrateIncentives"] = MigrateIncentives.deploy({"from": deployer})

    # Deploy logic contracts
    contracts["Governance"] = GovernanceAction.deploy({"from": deployer})

    if network.show_active() in ["goerli", "mainnet"]:
        raise Exception("update governance deployment!")
    # Brownie and Hardhat do not compile to the same bytecode for this contract, during mainnet
    # deployment. Therefore, when we deploy to mainnet we actually deploy the artifact generated
    # by the hardhat deployment here. NOTE: this artifact must be generated, the artifact here will
    # not be correct for future upgrades.
    # contracts["Governance"] = deployArtifact("./scripts/mainnet/GovernanceAction.json", [],
    #   deployer, "Governance")
    contracts["Views"] = Views.deploy({"from": deployer})
    contracts["InitializeMarketsAction"] = InitializeMarketsAction.deploy({"from": deployer})
    contracts["nTokenAction"] = nTokenAction.deploy({"from": deployer})
    contracts["BatchAction"] = BatchAction.deploy({"from": deployer})
    contracts["AccountAction"] = AccountAction.deploy({"from": deployer})
    contracts["ERC1155Action"] = ERC1155Action.deploy({"from": deployer})
    contracts["LiquidateCurrencyAction"] = LiquidateCurrencyAction.deploy({"from": deployer})
    contracts["CalculationViews"] = CalculationViews.deploy({"from": deployer})
    contracts["LiquidatefCashAction"] = LiquidatefCashAction.deploy({"from": deployer})
    contracts["TreasuryAction"] = TreasuryAction.deploy(kwargs["Comptroller"], kwargs["RebalancingStrategy"], {"from": deployer})
    contracts["VaultAction"] = VaultAction.deploy({"from": deployer})
    contracts["VaultAccountAction"] = VaultAccountAction.deploy({"from": deployer})
    contracts["VaultLiquidationAction"] = VaultLiquidationAction.deploy({"from": deployer})
    contracts["VaultAccountHealth"] = VaultAccountHealth.deploy({"from": deployer})

    # Deploy Pause Router
    pauseRouter = PauseRouter.deploy(
        contracts["Views"].address,
        contracts["LiquidateCurrencyAction"].address,
        contracts["LiquidatefCashAction"].address,
        contracts["CalculationViews"].address,
        contracts["VaultAccountHealth"].address,
        {"from": deployer},
    )

    # Deploy router
    router = Router.deploy(
        (
            contracts["Governance"].address,
            contracts["Views"].address,
            contracts["InitializeMarketsAction"].address,
            contracts["nTokenAction"].address,
            contracts["BatchAction"].address,
            contracts["AccountAction"].address,
            contracts["ERC1155Action"].address,
            contracts["LiquidateCurrencyAction"].address,
            contracts["LiquidatefCashAction"].address,
            contracts["TreasuryAction"].address,
            contracts["CalculationViews"].address,
            contracts["VaultAccountAction"].address,
            contracts["VaultAction"].address,
            contracts["VaultLiquidationAction"].address,
            contracts["VaultAccountHealth"].address,
        ),
        {"from": deployer},
    )

    return (router, pauseRouter, contracts)


def deployNotional(deployer, guardianAddress, comptroller):
    # NOTE: rebalancing strategy is only tested on mainnet fork
    (router, pauseRouter, contracts) = deployNotionalContracts(
        deployer, Comptroller=comptroller, RebalancingStrategy=ZERO_ADDRESS
    )

    initializeData = web3.eth.contract(abi=Router.abi).encodeABI(
        fn_name="initialize", args=[deployer.address, pauseRouter.address, guardianAddress]
    )

    proxy = nProxy.deploy(
        router.address, initializeData, {"from": deployer}  # Deployer is set to owner
    )

    deployBeacons(deployer, proxy)

    notionalInterfaceABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
    notional = Contract.from_abi(
        "Notional", proxy.address, abi=notionalInterfaceABI, owner=deployer
    )

    return (pauseRouter, router, proxy, notional, contracts)


def deployArtifact(path, constructorArgs, deployer, name):
    with open(path, "r") as a:
        artifact = json.load(a)

    createdContract = network.web3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"])
    txn = createdContract.constructor(*constructorArgs).buildTransaction(
        {"from": deployer.address, "nonce": deployer.nonce}
    )
    # This does a manual deployment of a contract
    tx_receipt = deployer.transfer(data=txn["data"])

    return Contract.from_abi(name, tx_receipt.contract_address, abi=artifact["abi"], owner=deployer)


class TestEnvironment:
    def __init__(self, deployer, withGovernance=False, multisig=None):
        self.deployer = deployer
        # Proxy Admin is just used for testing V1 contracts
        self.proxyAdmin = nProxyAdmin.deploy({"from": self.deployer})

        self.compPriceOracle = deployArtifact(
            "scripts/artifacts/nPriceOracle.json", [], self.deployer, "nPriceOracle"
        )
        self.comptroller = deployArtifact(
            "scripts/artifacts/nComptroller.json", [], self.deployer, "nComptroller"
        )
        self.comptroller._setMaxAssets(20)
        self.comptroller._setPriceOracle(self.compPriceOracle.address)
        self.currencyId = {}
        self.token = {"ETH": zeroAddress}
        self.ethOracle = {"ETH": zeroAddress}
        self.cToken = {}
        self.cTokenAggregator = {}
        self.nToken = {}
        self.router = {}
        self.primeCashOracle = {}
        self.multisig = multisig
        self.primeCashScalars = {"ETH": 50, "DAI": 49, "USDC": 48, "WBTC": 47}
        self.symbol = {}

        if withGovernance:
            self._deployGovernance()
        else:
            self._deployNoteERC20()

        # Deploys WETH using the same account and nonce so that we get the proper WETH address
        # on mainnet
        wethDeployer = accounts.at("0x4f26ffbe5f04ed43630fdc30a87638d53d0b0876", force=True)
        rpc.backend._request(
            "evm_setAccountNonce", ["0x4f26ffbe5f04ed43630fdc30a87638d53d0b0876", 446]
        )
        self.WETH = MockWETH.deploy({"from": wethDeployer})
        self.COMP = MockERC20.deploy("Compound", "COMP", 18, 0, {"from": self.deployer})

        # First deploy tokens to ensure they are available
        self._deployMockCurrency("ETH")
        for symbol in TokenConfig.keys():
            if symbol == "COMP":
                continue
            self._deployMockCurrency(symbol)

        self._deployNotional()

        if withGovernance:
            self.notional.transferOwnership(self.governor.address, True)
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
            self.noteERC20.transferOwnership(self.governor.address, {"from": self.deployer})
        else:
            self.noteERC20.initialize(
                [self.deployer, self.notional.address],
                [99_000_000e8, GovernanceConfig["initialBalances"]["NOTIONAL"]],
                self.deployer.address,
                {"from": self.deployer},
            )

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
            interestRateModel = deployArtifact(
                "scripts/artifacts/nWhitePaperInterestRateModel.json",
                [
                    config["interestRateModel"]["baseRate"],
                    config["interestRateModel"]["multiplier"],
                ],
                self.deployer,
                "InterestRateModel",
            )
        elif config["interestRateModel"]["name"] == "jump":
            interestRateModel = deployArtifact(
                "scripts/artifacts/nJumpRateModel.json",
                [
                    config["interestRateModel"]["baseRate"],
                    config["interestRateModel"]["multiplier"],
                    config["interestRateModel"]["jumpMultiplierPerYear"],
                    config["interestRateModel"]["kink"],
                ],
                self.deployer,
                "JumpRateModel",
            )

        if symbol == "ETH":
            cToken = deployArtifact(
                "scripts/artifacts/nCEther.json",
                [
                    self.comptroller.address,
                    interestRateModel.address,
                    config["initialExchangeRate"],
                    "Compound Ether",
                    "cETH",
                    8,
                    self.deployer.address,
                ],
                self.deployer,
                "cETH",
            )
        else:
            cToken = deployArtifact("scripts/artifacts/nCErc20.json", [], self.deployer, "cErc20")

            # Super hack but only way to initialize the cToken given the ABI
            zero = accounts.at(zeroAddress, force=True)
            cToken.initialize(
                underlyingToken.address,
                self.comptroller.address,
                interestRateModel.address,
                config["initialExchangeRate"],
                "Compound " + symbol,  # This is not exactly correct but whatever
                "c" + symbol,
                8,
                {"from": zero},
            )
            accounts.remove(zeroAddress)

        self.comptroller._supportMarket(cToken.address, {"from": self.deployer})
        self.comptroller._setCollateralFactor(
            cToken.address, 750000000000000000, {"from": self.deployer}
        )
        if symbol != "ETH":
            self.compPriceOracle.setUnderlyingPrice(cToken.address, rate)

        self.cToken[symbol] = cToken
        self.cTokenAggregator[symbol] = cTokenV2Aggregator.deploy(
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
        (self.pauseRouter, self.router, self.proxy, self.notional, _) = deployNotional(
            self.deployer, accounts[8].address, self.comptroller
        )
        self.enableCurrency("ETH", CurrencyDefaults)

    def enableCurrency(self, symbol, config):
        if symbol == "ETH":
            tokenDecimals = 18
            # need to init the list currency with some amount of tokens
            self.deployer.transfer(self.notional, 1e18)
        else:
            tokenDecimals = self.token[symbol].decimals()
            # need to init the list currency with some amount of tokens
            self.token[symbol].transfer(self.notional, 10 ** tokenDecimals, {"from": self.deployer})

        self.primeCashOracle[symbol] = CompoundV2HoldingsOracle.deploy(
            [self.notional.address, self.token[symbol], self.cToken[symbol].address, self.cTokenAggregator[symbol].address],
            {"from": self.deployer},
        )

        txn = self.notional.listCurrency(
            (
                self.token[symbol],
                symbol == "USDT",
                TokenType["UnderlyingToken"] if symbol != "ETH" else TokenType["Ether"],
                tokenDecimals,
                0,
            ),
            (
                self.ethOracle[symbol],
                18,
                False,
                config["buffer"],
                config["haircut"],
                config["liquidationDiscount"],
            ),
            PrimeCashCurve,
            self.primeCashOracle[symbol],
            True,  # allowDebt
            12,
            symbol,
            symbol
        )
        currencyId = txn.events["ListCurrency"]["newCurrencyId"]

        self.notional.enableCashGroup(
            currencyId,
            (
                config["maxMarketIndex"],
                config["rateOracleTimeWindow"],
                config["maxDiscountFactor"],
                config["reserveFeeShare"],
                config["debtBuffer"],
                config["fCashHaircut"],
                config["settlementPenalty"],
                config["liquidationfCashDiscount"],
                config["liquidationDebtBuffer"],
                config["minOracleRate"][0 : config["maxMarketIndex"]],
                config["maxOracleRate"][0 : config["maxMarketIndex"]],
            ),
            self.token[symbol].name() if symbol != "ETH" else "Ether",
            symbol,
        )

        self.currencyId[symbol] = currencyId
        self.symbol[currencyId] = symbol
        nTokenAddress = self.notional.nTokenAddress(currencyId)
        self.nToken[currencyId] = Contract.from_abi(
            "nToken", nTokenAddress, abi=nTokenERC20Proxy.abi, owner=self.deployer
        )

    def approxInternal(self, symbol, primeCash, underlyingInternal, abs=150):
        currencyId = self.currencyId[symbol]
        decimals = 18 if symbol == "ETH" else self.token[symbol].decimals()
        expectedInternal = (
            self.notional.convertCashBalanceToExternal(currencyId, primeCash, True)
            * 1e8
            / (10 ** decimals)
        )
        return pytest.approx(expectedInternal, abs=abs) == underlyingInternal

    def approxExternal(self, symbol, primeCash, underlyingExternal):
        currencyId = self.currencyId[symbol]
        precision = 5e10 if symbol == "ETH" or self.token[symbol].decimals() > 8 else 5
        expectedExternal = self.notional.convertCashBalanceToExternal(currencyId, primeCash, True)
        return pytest.approx(expectedExternal, abs=precision) == underlyingExternal


def main():
    env = TestEnvironment(accounts[0])
    for symbol in TokenConfig.keys():
        config = copy(CurrencyDefaults)
        if symbol == "USDT":
            config["haircut"] = 0
        elif symbol == "COMP":
            continue

        env.enableCurrency(symbol, config)

    return env
