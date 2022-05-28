import json

from brownie import accounts, cTokenV2Aggregator, network
from brownie.network.contract import Contract
from brownie.project import ContractsV2Project


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    notionalInterfaceABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
    notional = Contract.from_abi("Notional", output["notional"], abi=notionalInterfaceABI)

    for (i, symbol) in enumerate(["ETH", "DAI", "USDC", "WBTC"]):
        cTokenAddress = output["compound"]["ctokens"][symbol]["address"]
        agg = cTokenV2Aggregator.deploy(cTokenAddress, {"from": deployer})
        output["compound"]["ctokens"][symbol]["aggregator"] = agg.address
        print("Upgrade calldata:")
        print(notional.updateAssetRate.encode_input(i + 1, agg.address))

    with open(output_file, "w") as f:
        json.dump(output, f, indent=4, sort_keys=True)
