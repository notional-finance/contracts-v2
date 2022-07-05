import json

from brownie import accounts, cTokenLegacyAggregator, cTokenV2Aggregator, network
from brownie.network.contract import Contract
from brownie.project import ContractsV2Project


def main():
    networkName = network.show_active()
    if networkName == "mainnet-fork":
        networkName = "mainnet"
    deployer = accounts.load(networkName.upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(networkName)
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    notionalInterfaceABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
    notional = Contract.from_abi("Notional", output["notional"], abi=notionalInterfaceABI)

    for (i, symbol) in enumerate(["ETH", "DAI", "USDC", "WBTC"]):
        cTokenAddress = output["compound"]["ctokens"][symbol]["address"]
        if symbol in ["ETH", "USDC"]:
            agg = cTokenLegacyAggregator.deploy(
                cTokenAddress, {"from": deployer}, publish_source=True
            )
        else:
            agg = cTokenV2Aggregator.deploy(cTokenAddress, {"from": deployer}, publish_source=True)
        output["compound"]["ctokens"][symbol]["aggregator"] = agg.address
        print("Upgrade calldata:")
        print(notional.updateAssetRate.encode_input(i + 1, agg.address))

    with open(output_file, "w") as f:
        json.dump(output, f, indent=4, sort_keys=True)


# Transaction sent: 0x08c85498dffe74d6f192c8d72df67b19f02bbdd773e177c71d94d215aa47b15c
#   Gas price: 38.233537603 gwei   Gas limit: 1030585   Nonce: 98
#   cTokenLegacyAggregator.constructor confirmed   Block: 14914805   Gas used: 936896 (90.91%)
#   cTokenLegacyAggregator deployed at: 0x8E3D447eBE244db6D28E2303bCa86Ef3033CFAd6
# Upgrade calldata:
# 0xa508eca000000000000000000000000000000000000000000000000000000000000000010000000000000000000000008e3d447ebe244db6d28e2303bca86ef3033cfad6

# Transaction sent: 0xe8f2eb1c5e59f738326a885ce742e83e50cd5584833f3cc0684e5b76b4dc1cb9
#   Gas price: 14.417036325 gwei   Gas limit: 1030177   Nonce: 90
#   cTokenV2Aggregator.constructor confirmed   Block: 14860553   Gas used: 936525 (90.91%)
#   cTokenV2Aggregator deployed at: 0x719993E82974f5b5eA0c5ebA25c260CD5AF78E00
# Upgrade calldata:
# 0xa508eca00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000719993e82974f5b5ea0c5eba25c260cd5af78e00

# Transaction sent: 0x70a76d323a4885fd8bece917c54e6bf337456a285793d468f539075d8a9741d2
#   Gas price: 33.223049001 gwei   Gas limit: 1030561   Nonce: 99
#   cTokenLegacyAggregator.constructor confirmed   Block: 14914817   Gas used: 936874 (90.91%)
#   cTokenLegacyAggregator deployed at: 0x612741825ACedC6F88D8709319fe65bCB015C693
# Upgrade calldata:
# 0xa508eca00000000000000000000000000000000000000000000000000000000000000003000000000000000000000000612741825acedc6f88d8709319fe65bcb015c693

# Transaction sent: 0xbe614ac345903950ecde6003b94a73292e268a201534c1dff8aa0c4f28e916e2
#   Gas price: 16.018622736 gwei   Gas limit: 1030201   Nonce: 92
#   cTokenV2Aggregator.constructor confirmed   Block: 14860760   Gas used: 936547 (90.91%)
#   cTokenV2Aggregator deployed at: 0x39D9590721331B13C8e9A42941a2B961B513E69d

# Upgrade calldata:
# 0xa508eca0000000000000000000000000000000000000000000000000000000000000000400000000000000000000000039d9590721331b13c8e9a42941a2b961b513e69d
