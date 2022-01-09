from brownie import ChainlinkAdapter, accounts, network
from scripts.mainnet.deploy_notional import verify

CHAINLINK_CONFIG = {
    "DAI/ETH": {
        "baseToUSD": "0xaed0c38402a5d19df6e4c03f4e2dced6e29c1ee9",  # DAI/USD
        "quoteToUSD": "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419",  # ETH/USD
        "description": "Notional DAI/ETH Chainlink Adapter",
    },
    "USDC/ETH": {
        "baseToUSD": "0x8fffffd4afb6115b954bd326cbe7b4ba576818f6",  # USDC/USD
        "quoteToUSD": "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419",  # ETH/USD
        "description": "Notional USDC/ETH Chainlink Adapter",
    },
    "BTC/ETH": {
        "baseToUSD": "0xf4030086522a5beea4988f8ca5b36dbc97bee88c",  # BTC/USD
        "quoteToUSD": "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419",  # ETH/USD
        "description": "Notional BTC/ETH Chainlink Adapter",
    },
}


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")

    pair = ""
    adapter = ChainlinkAdapter.deploy(
        CHAINLINK_CONFIG[pair]["baseToUSD"],
        CHAINLINK_CONFIG[pair]["quoteToUSD"],
        CHAINLINK_CONFIG[pair]["description"],
        {"from": deployer},
    )

    verify(
        adapter.address,
        [
            CHAINLINK_CONFIG[pair]["baseToUSD"],
            CHAINLINK_CONFIG[pair]["quoteToUSD"],
            CHAINLINK_CONFIG[pair]["description"],
        ],
    )
