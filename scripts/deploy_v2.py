from copy import copy
from brownie import accounts, network
from scripts.deployers.token_deployer import TokenDeployer
from scripts.deployers.compound_deployer import CompoundDeployer
from scripts.deployers.gov_deployer import GovDeployer
from scripts.deployers.notional_deployer import NotionalDeployer
from scripts.deployers.liq_deployer import LiqDeployer
from scripts.initializers.notional_initializer import NotionalInitializer
from scripts.initializers.compound_initializer import CompoundInitializer
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
    initializer = CompoundInitializer(network.show_active(), deployer)
    initializer.initCToken("ETH")
    initializer.initCToken("DAI")
    initializer.initCToken("USDC")
    initializer.initCToken("WBTC")

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
    initializer = NotionalInitializer(network.show_active(), deployer)
    for symbol in TokenConfig.keys():
        initializer.enableCurrency(symbol, CurrencyDefaults)

def deployLiquidator(deployer):
    liq = LiqDeployer(network.show_active(), deployer)
    liq.deployExchange()
    liq.deployFlashLender()
    liq.deployFlashLiquidator()
    liq.deployManualLiquidator(1)
    liq.deployManualLiquidator(2)
    liq.deployManualLiquidator(3)
    liq.deployManualLiquidator(4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    deployTokens(deployer)
    deployCompound(deployer)
    deployGovernance(deployer)
    deployNotional(deployer)
    deployLiquidator(deployer)
