import json
import os

from brownie import accounts, network

EnvironmentConfig = {
    "kovan": {
        "UniswapWETHDAI": "0x4ba1d028e053A53842Ce31b0357C5864B40Ef909",
    },
}

def main():
    # Load the deployment address
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    print(deployer)