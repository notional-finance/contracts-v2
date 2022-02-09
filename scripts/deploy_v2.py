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
    tokens.load()
    tokens.deployERC20("Notional WETH", "WETH", 18, 0)
    tokens.deployERC20("Notional DAI", "DAI", 18, 0)
    tokens.deployERC20("Notional USDC", "USDC", 6, 0)
    tokens.deployERC20("Notional WBTC", "WBTC", 8, 0)
    tokens.deployERC20("Notional COMP", "COMP", 18, 0)
    tokens.save()

def deployCompound(deployer):
    ctokens = CompoundDeployer(network.show_active(), deployer)
    ctokens.load()
    ctokens.deployComptroller()
    ctokens.deployCToken("ETH")
    ctokens.deployCToken("DAI")
    ctokens.deployCToken("USDC")
    ctokens.deployCToken("WBTC")
    ctokens.save()

def deployGovernance(deployer):
    gov = GovDeployer(network.show_active(), deployer)
    gov.load()
    gov.deployNOTE()
    gov.deployAirdrop()
    gov.deployGovernor()
    gov.save()

def deployNotional(deployer):
    notional = NotionalDeployer(network.show_active(), deployer)
    notional.load()
    notional.deployLibs()
    notional.deployActions()
    notional.deployPauseRouter()
    notional.deployRouter()
    notional.deployProxy()
    notional.save()

def deployLiquidator(deployer):
    pass

def initNotional(deployer):
    initializer = NotionalInitializer(network.show_active(), deployer)
    initializer.load()
    for symbol in TokenConfig.keys():
        config = copy(CurrencyDefaults)
        if symbol == "USDT":
            config["haircut"] = 0
        initializer.enableCurrency(symbol, config)
    initializer.save()

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    deployTokens(deployer)
    deployCompound(deployer)
    deployGovernance(deployer)
    deployNotional(deployer)
    initNotional(deployer)
    deployLiquidator(deployer)
