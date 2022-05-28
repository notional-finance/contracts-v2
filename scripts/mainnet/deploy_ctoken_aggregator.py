import json

from brownie import accounts, cTokenV2Aggregator, network
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
        agg = cTokenV2Aggregator.deploy(cTokenAddress, {"from": deployer}, publish_source=True)
        output["compound"]["ctokens"][symbol]["aggregator"] = agg.address
        print("Upgrade calldata:")
        print(notional.updateAssetRate.encode_input(i + 1, agg.address))

    with open(output_file, "w") as f:
        json.dump(output, f, indent=4, sort_keys=True)


# Transaction sent: 0x91e248d2497ef29d0454398175b1f6c65a88707bb1ab30545027d61a3303fa05
#   Gas price: 12.973142188 gwei   Gas limit: 1030103   Nonce: 89
#   cTokenV2Aggregator.constructor confirmed   Block: 14860547   Gas used: 936458 (90.91%)
#   cTokenV2Aggregator deployed at: 0xE329E81800219Aefeef79D74DB35f8877fE1abdE
# Upgrade calldata:
# 0xa508eca00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e329e81800219aefeef79d74db35f8877fe1abde

# Transaction sent: 0xe8f2eb1c5e59f738326a885ce742e83e50cd5584833f3cc0684e5b76b4dc1cb9
#   Gas price: 14.417036325 gwei   Gas limit: 1030177   Nonce: 90
#   cTokenV2Aggregator.constructor confirmed   Block: 14860553   Gas used: 936525 (90.91%)
#   cTokenV2Aggregator deployed at: 0x719993E82974f5b5eA0c5ebA25c260CD5AF78E00
# Upgrade calldata:
# 0xa508eca00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000719993e82974f5b5ea0c5eba25c260cd5af78e00

# Transaction sent: 0x4ecbd0a5c59e90bff2a9b3ab0e39991f7fdd0e38c99013c98e4447d047004b8f
#   Gas price: 13.379328858 gwei   Gas limit: 1030079   Nonce: 91
#   cTokenV2Aggregator.constructor confirmed   Block: 14860564   Gas used: 936436 (90.91%)
#   cTokenV2Aggregator deployed at: 0x7b0cc121ABd20ACd77482b5aa95126db2e597987

# Upgrade calldata:
# 0xa508eca000000000000000000000000000000000000000000000000000000000000000030000000000000000000000007b0cc121abd20acd77482b5aa95126db2e597987

# Transaction sent: 0xbe614ac345903950ecde6003b94a73292e268a201534c1dff8aa0c4f28e916e2
#   Gas price: 16.018622736 gwei   Gas limit: 1030201   Nonce: 92
#   cTokenV2Aggregator.constructor confirmed   Block: 14860760   Gas used: 936547 (90.91%)
#   cTokenV2Aggregator deployed at: 0x39D9590721331B13C8e9A42941a2B961B513E69d

# Upgrade calldata:
# 0xa508eca0000000000000000000000000000000000000000000000000000000000000000400000000000000000000000039d9590721331b13c8e9a42941a2b961b513e69d
