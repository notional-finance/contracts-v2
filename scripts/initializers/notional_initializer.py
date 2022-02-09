import json
from brownie import accounts, network, ZERO_ADDRESS
from scripts.common import TokenType, loadContractFromABI, loadContractFromArtifact, hasTransferFee

class NotionalInitializer:
    def __init__(self, network, deployer) -> None:
        self.tokens = {}
        self.ctokens = {}
        self.ethOracles = {}
        self.notional = None
        self.network = network
        self.deployer = deployer

    def _listCurrency(self, symbol, asset, underlying, config):
        if symbol not in self.ethOracles:
            raise Exception("{} not found in ethOracles".format(symbol))

        txn = self.notional.listCurrency(
            asset,
            underlying,
            self.ethOracle[symbol],
            False,
            config["buffer"],
            config["haircut"],
            config["liquidationDiscount"],
            {"from": self.deployer}
        )
        return txn.events["ListCurrency"]["newCurrencyId"]

    def enableCurrency(self, symbol, config):
        if self.notional is None:
            raise Exception("NotionalProxy not defined")

        currencyId = 1
        if symbol == "NOMINT":
            if symbol not in self.tokens:
                raise Exception("{} not found in tokens".format(symbol))
            address = self.tokens[symbol].address
            decimals = self.token[symbol].decimals()
            asset = (address, hasTransferFee(symbol), TokenType["NonMintable"], decimals)
            underlying = (ZERO_ADDRESS, False, 0, 0, 0)
            currencyId = self._listCurrency(symbol, asset, underlying, config)
        elif symbol != "ETH":
            if symbol not in self.tokens:
                raise Exception("{} not found in tokens".format(symbol))
            if symbol not in self.ctokens:
                raise Exception("{} not found in ctokens".format(symbol))
            assetAddress = self.ctokens[symbol].address
            assetDecimals = self.ctokens[symbol].decimals()
            underlyingAddress = self.tokens[symbol].address
            underlyingDecimals = self.tokens[symbol].decimals()
            asset = (assetAddress, hasTransferFee(symbol), TokenType["cToken"], assetDecimals, 0)
            underlying = (underlyingAddress, hasTransferFee(symbol), TokenType["UnderlyingToken"], underlyingDecimals, 0)
            currencyId = self._listCurrency(symbol, asset, underlying, config)

        if symbol == "NOMINT":
            assetRateAddress = ZERO_ADDRESS
        else:
            assetRateAddress = self.cTokenAggregator[symbol].address

        self.notional.enableCashGroup(
            currencyId,
            assetRateAddress,
            (
                config["maxMarketIndex"],
                config["rateOracleTimeWindow"],
                config["totalFee"],
                config["reserveFeeShare"],
                config["debtBuffer"],
                config["fCashHaircut"],
                config["settlementPenalty"],
                config["liquidationfCashDiscount"],
                config["liquidationDebtBuffer"],
                config["tokenHaircut"][0 : config["maxMarketIndex"]],
                config["rateScalar"][0 : config["maxMarketIndex"]],
            ),
            self.token[symbol].name() if symbol != "ETH" else "Ether",
            symbol,
            {"from": self.deployer}
        )

    def load(self):
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "notional" in self.config:
            self.notional = loadContractFromABI("NotionalProxy", self.config["notional"], "abi/Notional.json")
        if "tokens" in self.config:
            tokens = self.config["tokens"]
            for k, v in tokens.items():
                if "address" in v:
                    self.tokens[k] = loadContractFromABI(k, v["address"], "abi/ERC20.json")
                if "oracle" in v:
                    self.ethOracle[k] = v["oracle"]
        else:
            raise Exception("Tokens not deployed")
        if "compound" in self.config and "ctokens" in self.config["compound"]:
            ctokens = self.config["compound"]["ctokens"]
            for k, v in ctokens.items():
                if "address" in v:
                    if k == "ETH":
                        path = "scripts/compound_artifacts/nCEther.json"
                    else:
                        path = "scripts/compound_artifacts/nCErc20.json"
                    self.ctokens[k] = loadContractFromArtifact(k, v["address"], path)
                    
        else:
            raise Exception("Compound not deployed")


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    initializer = NotionalInitializer(network.show_active(), deployer)
    initializer.load()