import json
from brownie import network, NotionalV21PatchFix
from scripts.environment_v2 import EnvironmentV2

def main():
    networkName = network.show_active()
    if networkName == "hardhat-fork":
        networkName = "mainnet"
    with open("v2.{}.json".format(networkName), "r") as f:
        config = json.load(f)
    env = EnvironmentV2(config)
    env.notional.upgradeTo("0x774d65f16Fc367a4e62d1986799c394d7036843c", {"from": env.notional.owner()})
    env.notional.transferOwnership("0x99eB7cBCF119dC2A93038F98153909F80eC3fCA8", False, {"from": env.notional.owner()})
    patch = NotionalV21PatchFix.at("0x99eB7cBCF119dC2A93038F98153909F80eC3fCA8")
    patch.atomicPatchAndUpgrade({"from": env.notional.owner()})