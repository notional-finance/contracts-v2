import json

from brownie import NotionalV1ToNotionalV2, accounts, network
from scripts.mainnet.deploy_notional import verify

V1_CONFIG = {
    "kovan": {
        "escrow": "0x9abd0b8868546105F6F48298eaDC1D9c82f7f683",
        "erc1155trade": "0xBbA899578bd3fA3DAa863A340f5600797993eF08",
        "weth": "0xd0a1e359811322d97991e03f863a0c30c2cf029c",
        "wbtc": "0x45a8451ceaae5976b4ae5f14a7ad789fae8e9971",
        "cETH": "0x40575f9Eb401f63f66F4c434248ad83D3441bf61",
    },
    "mainnet": {
        "escrow": "0x9abd0b8868546105F6F48298eaDC1D9c82f7f683",
        "erc1155trade": "0xBbA899578bd3fA3DAa863A340f5600797993eF08",
        "weth": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "wbtc": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
        "cETH": "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5",
    },
}


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    config = V1_CONFIG[network.show_active()]
    v1ToV2 = NotionalV1ToNotionalV2.deploy(
        config["escrow"],
        output["notional"],
        config["erc1155trade"],
        config["weth"],
        config["wbtc"],
        {"from": deployer},
    )

    verify(
        v1ToV2.address,
        [
            config["escrow"],
            output["notional"],
            config["erc1155trade"],
            config["weth"],
            config["wbtc"],
        ],
    )
