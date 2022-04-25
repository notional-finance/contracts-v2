import json
import os

from brownie import NoteERC20, accounts
from scripts.deployment import deployArtifact

IncentiveAirdropTree = json.load(
    open(os.path.join(os.path.dirname(__file__), "IncentiveAirdropTree.json"), "r")
)


def main():
    deployer = accounts.load("KOVAN_DEPLOYER")
    output_file = "v2.kovan.json"
    addresses = None
    with open(output_file, "r") as f:
        addresses = json.load(f)

    note = NoteERC20.at(addresses["note"])
    noteWhale = accounts.at("0x4ba1d028e053A53842Ce31b0357C5864B40Ef909", force=True)

    airdrop = deployArtifact(
        os.path.join(os.path.dirname(__file__), "MerkleDistributor.json"),
        [addresses["note"], IncentiveAirdropTree["merkleRoot"], 0],  # Can claim immediately
        deployer,
        "IncentiveAirdrop",
    )

    note.transfer(airdrop.address, IncentiveAirdropTree["tokenTotal"], {"from": noteWhale})
