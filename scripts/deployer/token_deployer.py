import json
import subprocess

from brownie import accounts, network, MockWETH, MockERC20

# Mainnet token addresses
TokenAddress = {
    "WETH": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    "DAI": "0x6b175474e89094c44da98b954eedeac495271d0f",
    "USDC": "",
    "WBTC": "",
    "COMP": ""
}

class TokenDeployer:
    def __init__(self, network, deployer) -> None:
        self.tokens = {}
        self.network = network
        self.deployer = deployer

    def load(self):
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "tokens" in self.config:
            self.tokens = self.config["tokens"]

    def deploy(self, name, symbol, decimals, fee):
        # Save token address directly for mainnet and mainnet fork
        if self.network == "mainnet" or self.network == "hardhat-fork":
            self.tokens[symbol] = TokenAddress[symbol]
        else:
            if symbol not in self.tokens:
                if symbol == "WETH":
                    token = MockWETH.deploy({"from": self.deployer})
                    args = []
                else:
                    token = MockERC20.deploy(name, symbol, decimals, fee, {"from": self.deployer})
                    args = [name, symbol, decimals, fee]
                if self.network != "development":
                    self.verify(token.address, args)
                self.tokens[symbol] = token.address

    def verify(self, address, args):
        proc = subprocess.run(
            ["npx", "hardhat", "verify", "--network", network.show_active(), address] + args,
            capture_output=True,
            encoding="utf8",
        )
        print(proc.stdout)
        print(proc.stderr)

    def save(self):
        self.config["tokens"] = self.tokens
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    tokens = TokenDeployer(network.show_active(), deployer)
    tokens.load()
    tokens.deploy("Notional WETH", "WETH", 18, 0)
    tokens.deploy("Notional DAI", "DAI", 18, 0)
    tokens.save()
