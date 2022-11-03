from brownie import accounts, network
from scripts.config import CurrencyConfig, nTokenConfig
from scripts.deployers.compound_deployer import CompoundDeployer
from scripts.deployers.gov_deployer import GovDeployer
from scripts.deployers.liq_deployer import LiqDeployer
from scripts.deployers.notional_deployer import NotionalDeployer
from scripts.deployers.token_deployer import TokenDeployer
from scripts.initializers.compound_initializer import CompoundInitializer
from scripts.initializers.gov_initializer import GovInitializer
from scripts.initializers.notional_initializer import NotionalInitializer


def deployTokens(deployer):
    tokens = TokenDeployer(network.show_active(), deployer)
    tokens.deployERC20("Notional WETH", "WETH", 18, 0)
    tokens.deployERC20("Notional DAI", "DAI", 18, 0)
    tokens.deployERC20("Notional USDC", "USDC", 6, 0)
    tokens.deployERC20("Notional WBTC", "WBTC", 8, 0)
    tokens.deployERC20("Notional COMP", "COMP", 18, 0)
    tokens.deployERC20("Notional wstETH", "wstETH", 18, 0)


def deployCompound(deployer):
    ctokens = CompoundDeployer(network.show_active(), deployer)
    ctokens.deployComptroller()
    ctokens.deployCToken("ETH")
    ctokens.deployCToken("DAI")
    ctokens.deployCToken("USDC")
    ctokens.deployCToken("WBTC")
    initializer = CompoundInitializer(network.show_active(), deployer)
    initializer.initCToken("ETH")
    initializer.initCToken("DAI")
    initializer.initCToken("USDC")
    initializer.initCToken("WBTC")


def deployGovernance(deployer):
    gov = GovDeployer(network.show_active(), deployer)
    gov.deployNOTE()
    gov.deployGovernor()
    initializer = GovInitializer(network.show_active(), deployer)
    initializer.initNOTE([deployer.address], [initializer.note.totalSupply()])


def deployNotional(deployer, networkName, dryRun):
    notional = NotionalDeployer(networkName, deployer, dryRun)
    notional.deployLibs()
    notional.deployActions()
    notional.deployPauseRouter()
    notional.deployRouter()
    notional.deployProxy()
    initializer = NotionalInitializer(networkName, deployer, dryRun)
    initializer.enableCurrency(1, CurrencyConfig)
    initializer.enableCurrency(2, CurrencyConfig)
    initializer.enableCurrency(3, CurrencyConfig)
    initializer.enableCurrency(4, CurrencyConfig)
    initializer.updateGovParameters(1, nTokenConfig, CurrencyConfig)
    initializer.updateGovParameters(2, nTokenConfig, CurrencyConfig)
    initializer.updateGovParameters(3, nTokenConfig, CurrencyConfig)
    initializer.updateGovParameters(4, nTokenConfig, CurrencyConfig)
    initializer.initializeMarkets(1, 1e18)
    initializer.initializeMarkets(2, 1000000e18)
    initializer.initializeMarkets(3, 1000000e6)
    initializer.initializeMarkets(4, 10000e8)


def deployLiquidator(deployer, networkName):
    liq = LiqDeployer(networkName, deployer)
    liq.deployExchange()
    liq.deployFlashLender()
    liq.deployFlashLiquidator()
    liq.deployManualLiquidator(1)
    liq.deployManualLiquidator(2)
    liq.deployManualLiquidator(3)
    liq.deployManualLiquidator(4)


def main(dryRun=True):
    networkName = network.show_active()
    if networkName == "mainnet-fork":
        networkName = "mainnet"
    if networkName == "goerli-fork":
        networkName = "goerli"
    deployer = accounts.load(networkName.upper() + "_DEPLOYER")
    if networkName not in ["kovan", "mainnet", "goerli"]:
        deployTokens(deployer)
        deployCompound(deployer)
        deployGovernance(deployer)

    if dryRun == "LFG":
        txt = input("Will execute REAL transactions, are you sure (type 'I am sure'): ")
        if txt != "I am sure":
            return
        else:
            dryRun = False

    deployNotional(deployer, networkName, dryRun)
    deployLiquidator(deployer, networkName, dryRun)
