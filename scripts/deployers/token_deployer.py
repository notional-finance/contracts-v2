import json

from brownie import MockWETH, MockERC20, MockAggregator
from scripts.config import TokenConfig
from scripts.common import isProduction
from scripts.deployers.contract_deployer import ContractDeployer

# Production token addresses
TokenAddress = {
    "mainnet": {
        "WETH": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        "DAI": "0x6b175474e89094c44da98b954eedeac495271d0f",
        "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "WBTC": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
        "COMP": "0xc00e94cb662c3520282e6f5717214004a7f26888"
    }
}

# Production oracle addresses
OracleAddress = {
    "mainnet": {
        "DAI": "0x6085b0a8f4c7ffa2e8ca578037792d6535d1e29b",
        "USDC": "0x68225f47813af66f186b3714ffe6a91850bc76b4",
        "WBTC": "0x10aae34011c256a9e63ab5ac50154c2539c0f51d",
    }
}

class TokenDeployer:
    def __init__(self, network, deployer, config=None, persist=True) -> None:
        self.config = config
        if self.config == None:
            self.config = {}
        self.persist = persist
        self.tokens = {}
        self.network = network
        self.deployer = deployer
        self._load()

    def _load(self):
        print("Loading token config")
        if self.persist:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        if "tokens" in self.config:
            self.tokens = self.config["tokens"]

    def _save(self):
        print("Saving token config")
        self.config["tokens"] = self.tokens
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def _deployERC20Contract(self, token, name, symbol, decimals, fee):
        if "address" in token:
            print("{} already deployed at {}".format(symbol, token["address"]))
            return
                
        deployer = ContractDeployer(self.deployer)
        if symbol == "WETH":
            contract = deployer.deploy(MockWETH, [], "", True)
        else:
            contract = deployer.deploy(MockERC20, [name, symbol, decimals, fee], "", True)
        token["address"] = contract.address
        # Re-deploy dependent contracts
        token.pop("oracle", None)
        self.tokens[symbol] = token
        self._save()
        
    def _deployETHOracle(self, token, symbol):
        if "oracle" in token:
            print("{}/ETH oracle already deployed at {}".format(symbol, token["oracle"]))
            return

        deployer = ContractDeployer(self.deployer)
        contract = deployer.deploy(MockAggregator, [18], "", True)
        config = TokenConfig[symbol]
        contract.setAnswer(config["rate"], {"from": self.deployer})    
        token["oracle"] = contract.address
        self.tokens[symbol] = token
        self._save()

    def deployERC20(self, name, symbol, decimals, fee):
        if isProduction(self.network):
            self.tokens[symbol] = {
                "address": TokenAddress[self.network][symbol],
                "oracle": OracleAddress[self.network][symbol]
            }
            self._save()
            return

        token = {}
        if symbol in self.tokens:
            token = self.tokens[symbol]

        # Deploy and verify token contract            
        self._deployERC20Contract(token, name, symbol, decimals, fee)

        # Deploy price oracle
        if symbol == "WETH":
            print("Skipping price oracle deployment for WETH")
        else:
            self._deployETHOracle(token, symbol)
