import json

import scripts.deploy_v1
import scripts.deployment


def main():
    v2env = scripts.deployment.main()
    v1env = scripts.deploy_v1.deploy_v1(v2env)

    contractsFile = {
        "chainId": 1337,
        "networkName": "unknown",
        "escrow": v1env["Escrow"].address,
        "portfolios": v1env["Portfolios"].address,
        "directory": v1env["Directory"].address,
        "erc1155": v1env["ERC1155Token"].address,
        "erc1155trade": v1env["ERC1155Trade"].address,
        "startBlock": 1,
    }

    with open("sandbox2.local.json", "w") as f:
        json.dump(contractsFile, f, sort_keys=True, indent=4)
