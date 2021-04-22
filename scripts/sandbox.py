import json

import scripts.deploy_v1
from brownie import accounts
from scripts.deployment import TestEnvironment


def main():
    v2env = TestEnvironment(accounts[0], withGovernance=True, multisig=accounts[0])
    v1env = scripts.deploy_v1.deploy_v1(v2env)

    v1contractsFile = {
        "chainId": 1337,
        "networkName": "unknown",
        "deployer": accounts[9].address,
        "escrow": v1env["Escrow"].address,
        "portfolios": v1env["Portfolios"].address,
        "directory": v1env["Directory"].address,
        "erc1155": v1env["ERC1155Token"].address,
        "erc1155trade": v1env["ERC1155Trade"].address,
        "startBlock": 1,
    }

    v2contractsFile = {
        "chainId": 1337,
        "networkName": "unknown",
        "deployer": v2env.deployer.address,
        "notional": v2env.notional.address,
        "note": v2env.noteERC20.address,
        "governor": v2env.governor.address,
        "comptroller": v2env.comptroller.address,
        "startBlock": 1,
    }

    with open("sandbox2.local.json", "w") as f:
        json.dump(v1contractsFile, f, sort_keys=True, indent=4)

    with open("v2.local.json", "w") as f:
        json.dump(v2contractsFile, f, sort_keys=True, indent=4)

    with open("abi/Governor.json", "w") as f:
        json.dump(v2env.governor.abi, f, sort_keys=True, indent=4)

    with open("abi/NoteERC20.json", "w") as f:
        json.dump(v2env.noteERC20.abi, f, sort_keys=True, indent=4)

    with open("abi/Notional.json", "w") as f:
        json.dump(v2env.notional.abi, f, sort_keys=True, indent=4)
