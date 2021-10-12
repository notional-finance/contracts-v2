import json
import re

from brownie import accounts, network
from scripts.deployment import deployNotionalContracts
from scripts.mainnet.deploy_notional import TokenConfig, etherscan_verify


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    print("Confirming that NOTE token is hardcoded properly in Constants.sol")
    with open("contracts/global/Constants.sol") as f:
        constants = f.read()
        m = re.search("address constant NOTE_TOKEN_ADDRESS = (.*);", constants)
        assert m.group(1) == output["note"]

    (router, pauseRouter, contracts) = deployNotionalContracts(
        deployer, TokenConfig[network.show_active()]["cETH"]
    )

    etherscan_verify(contracts, router, pauseRouter)

    print("New Router Implementation At: ", router.address)
