from brownie import accounts, network
from scripts.deployers.liq_deployer import LiqDeployer
from scripts.deployers.notional_deployer import NotionalDeployer


def deployNotional(deployer, networkName, dryRun):
    notional = NotionalDeployer(networkName, deployer, dryRun)
    notional.deployLibs()
    notional.deployActions()
    notional.deployPauseRouter()
    notional.deployRouter()
    notional.deployBeaconImplementation()


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
    if networkName in ["mainnet-fork", "mainnet-current"]:
        networkName = "mainnet"
    elif networkName in ["arbitrum-fork", "arbitrum-current"]:
        networkName = "arbitrum-one"
    deployer = accounts.load(networkName.upper() + "_DEPLOYER")
    print("Deployer Address: ", deployer.address)

    if dryRun == "LFG":
        txt = input("Will execute REAL transactions, are you sure (type 'I am sure'): ")
        if txt != "I am sure":
            return
        else:
            dryRun = False

    deployNotional(deployer, networkName, dryRun)
    # deployLiquidator(deployer, networkName, dryRun)