import json

from brownie import accounts, network, MockWETH, MockERC20, MockAggregator
from scripts.config import TokenConfig
from scripts.common import verifyContract, ContractDeployer, isMainnet

# Mainnet token addresses
TokenAddress = {
    "mainnet": {
        "WETH": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        "DAI": "0x6b175474e89094c44da98b954eedeac495271d0f",
        "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "WBTC": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
        "COMP": "0xc00e94cb662c3520282e6f5717214004a7f26888"
    }
}

# Mainnet oracle addresses
OracleAddress = {
    "mainnet": {
        "DAI": "0x6085b0a8f4c7ffa2e8ca578037792d6535d1e29b",
        "USDC": "0x68225f47813af66f186b3714ffe6a91850bc76b4",
        "WBTC": "0x10aae34011c256a9e63ab5ac50154c2539c0f51d",
    }
}

class TokenDeployer:
    def __init__(self, network, deployer) -> None:
        self.tokens = {}
        self.network = network
        self.deployer = deployer

    def _deployERC20Contract(self, name, symbol, decimals, fee):
        print("Deploying {}".format(symbol))
        if symbol == "WETH":
            token = MockWETH.deploy({"from": self.deployer}, publish_source=True)
        else:
            token = MockERC20.deploy(
                name, 
                symbol, 
                decimals, 
                fee, 
                {"from": self.deployer}, 
                publish_source=True
            )
        return token
        
    def _deployETHOracle(self, symbol):
        print("Deploying {}/ETH oracle".format(symbol))
        config = TokenConfig[symbol]
        oracle = MockAggregator.deploy(18, {"from": self.deployer}, publish_source=True)
        oracle.setAnswer(config["rate"])
        return oracle    

    def deployERC20(self, name, symbol, decimals, fee):
        if isMainnet(self.network):
            # Save token address directly for mainnet and mainnet fork
            self.tokens[symbol] = {
                "address": TokenAddress["mainnet"][symbol],
                "oracle": OracleAddress["mainnet"][symbol]
            }
        else:
            token = {}
            if symbol in self.tokens:
                token = self.tokens[symbol]

            # Deploy and verify token contract            
            if "address" in token:
                print("{} already deployed at {}".format(symbol, token["address"]))
            else:
                deployer = ContractDeployer()
                try:
                    t = self._deployERC20Contract(name, symbol, decimals, fee)
                    token["address"] = t.address
                except Exception as e:
                    print("Failed to deploy {}: {}".format(symbol, e))

            # Deploy price oracle
            if symbol == "WETH":
                print("Skipping price oracle deployment for WETH")
            else:
                if "oracle" in token:
                    print("{}/ETH oracle already deployed at {}".format(symbol, token["oracle"]))
                else:                    
                    try:
                        o = self._deployETHOracle(symbol)
                        token["oracle"] = o.address
                    except Exception as e:
                        print("Failed to deploy {}/ETH oracle: {}".format(symbol, e))

            self.tokens[symbol] = token

    def load(self):
        print("Loading token addresses")
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "tokens" in self.config:
            self.tokens = self.config["tokens"]

    def save(self):
        print("Saving token addresses")
        self.config["tokens"] = self.tokens
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    tokens = TokenDeployer(network.show_active(), deployer)
    tokens.load()
    tokens.deployERC20("Notional WETH", "WETH", 18, 0)
    tokens.deployERC20("Notional DAI", "DAI", 18, 0)
    tokens.deployERC20("Notional USDC", "USDC", 6, 0)
    tokens.deployERC20("Notional WBTC", "WBTC", 8, 0)
    tokens.deployERC20("Notional COMP", "COMP", 18, 0)
    tokens.save()
