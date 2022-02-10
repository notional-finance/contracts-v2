from copy import copy
from brownie import accounts, network
from scripts.deployers.token_deployer import TokenDeployer
from scripts.deployers.compound_deployer import CompoundDeployer
from scripts.deployers.gov_deployer import GovDeployer
from scripts.deployers.notional_deployer import NotionalDeployer
from scripts.deployers.liq_deployer import LiqDeployer
from scripts.initializers.notional_initializer import NotionalInitializer
from scripts.config import TokenConfig, CurrencyDefaults

def deployTokens(deployer):
    tokens = TokenDeployer(network.show_active(), deployer)
    tokens.deployERC20("Notional WETH", "WETH", 18, 0)
    tokens.deployERC20("Notional DAI", "DAI", 18, 0)
    tokens.deployERC20("Notional USDC", "USDC", 6, 0)
    tokens.deployERC20("Notional WBTC", "WBTC", 8, 0)
    tokens.deployERC20("Notional COMP", "COMP", 18, 0)

def deployCompound(deployer):
    ctokens = CompoundDeployer(network.show_active(), deployer)
    ctokens.deployComptroller()
    ctokens.deployCToken("ETH")
    ctokens.deployCToken("DAI")
    ctokens.deployCToken("USDC")
    ctokens.deployCToken("WBTC")

def deployGovernance(deployer):
    gov = GovDeployer(network.show_active(), deployer)
    gov.deployNOTE()
    gov.deployGovernor()

def deployNotional(deployer):
    notional = NotionalDeployer(network.show_active(), deployer)
    notional.deployLibs()
    notional.deployActions()
    notional.deployPauseRouter()
    notional.deployRouter()
    notional.deployProxy()

def deployLiquidator(deployer):
    pass

def initNotional(deployer):
    initializer = NotionalInitializer(network.show_active(), deployer)
    for symbol in TokenConfig.keys():
        initializer.enableCurrency(symbol, CurrencyDefaults)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    deployTokens(deployer)
    deployCompound(deployer)
    deployGovernance(deployer)
    deployNotional(deployer)
    initNotional(deployer)
    deployLiquidator(deployer)
