import json
import os

from brownie import accounts, network
from scripts.deployment import deployArtifact

IncentiveAirdropTree = json.load(
    open(os.path.join(os.path.dirname(__file__), "IncentiveAirdropTree.json"), "r")
)


def main():
    networkName = network.show_active()
    if networkName == "mainnet-fork":
        networkName = "mainnet"

    deployer = accounts.load(networkName.upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(networkName)
    addresses = None
    with open(output_file, "r") as f:
        addresses = json.load(f)

    airdrop = deployArtifact(
        os.path.join(os.path.dirname(__file__), "MerkleDistributor.json"),
        [addresses["note"], IncentiveAirdropTree["merkleRoot"], 0],  # Can claim immediately
        deployer,
        "IncentiveAirdrop",
    )
    print("Airdrop Deployed To: ", airdrop.address)
