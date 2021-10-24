from brownie import MockAaveFlashLender, accounts, network, interface
from scripts.liquidation import LiquidationConfig

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = LiquidationConfig[network.show_active()]
    lender = MockAaveFlashLender.deploy(config["WETH"], deployer.address, { "from": deployer })
    
    # Funding lender with WETH
    weth = interface.WETH9(config["WETH"])
    weth.deposit({"from": deployer, "value": 5e18})
    weth.transfer(lender.address, 5e18, {"from": deployer})
    
    # Funding lender with DAI
    daiToken = interface.IERC20(config["DAI"])
    daiToken.transfer(lender.address, 100e18, {"from": deployer})
    
    # Funding lender with USDC
    usdcToken = interface.IERC20(config["USDC"])
    usdcToken.transfer(lender.address, 100e6, {"from": deployer})

    # Funding lender with WBTC
    wbtcToken = interface.IERC20(config["WBTC"])
    wbtcToken.transfer(lender.address, 1e8, {"from": deployer})
