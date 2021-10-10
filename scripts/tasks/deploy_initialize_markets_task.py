import json
import os

from brownie import InitializeMarketsTask, accounts, network

EnvironmentConfig = {
    "kovan": {
        "WETH": "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
        "NotionalV2": "0x0EAE7BAdEF8f95De91fDDb74a89A786cF891Eb0e",
        "ETHInitTask": "0xF3a77bd5e1C8247EaEE265141706CfB9Ac0173E2"
    },
}

def main():
    # Deployer = 0x2a956Fe94ff89D8992107c8eD4805c30ff1106ef for kovan
    deployer = accounts.add("0x43a6634021d4b1ff7fd350843eebaa7cf547aefbf9503c33af0ec27c83f76827")
    config = EnvironmentConfig[network.show_active()]
    InitializeMarketsTask.deploy(1, config["NotionalV2"], deployer.address, {"from": deployer})    