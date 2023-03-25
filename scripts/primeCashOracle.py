from brownie import accounts, ZERO_ADDRESS, interface, CompoundV2HoldingsOracle

CompoundConfig = {
    "ETH": {
        "cToken": "0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5",
        "underlying": ZERO_ADDRESS
    },
    "DAI": {
        "cToken": "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",
        "underlying": "0x6B175474E89094C44Da98b954EedeAC495271d0F"
    },
    "USDC": {
        "cToken": "0x39AA39c021dfbaE8faC545936693aC917d5E7563",
        "underlying": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    },
    "WBTC": {
        "cToken": "0xccF4429DB6322D5C611ee964527D42E5d685DD6a",
        "underlying": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"
    }
}

class PrimeCashOracleEnvironment:
    def __init__(self) -> None:
        self.deployer = accounts.at("0xE6FB62c2218fd9e3c948f0549A2959B509a293C8", force=True)
        self.notional = interface.NotionalProxy("0x1344A36A1B56144C3Bc62E7757377D288fDE0369")
        self.compOracles = {
            "ETH": self.deployCompEulOracle(
                ZERO_ADDRESS, 
                CompoundConfig["ETH"]["cToken"],
                self.notional.getCurrencyAndRates(1)["assetRate"]["rateOracle"],
            ),
            "DAI": self.deployCompEulOracle(
                "0x6B175474E89094C44Da98b954EedeAC495271d0F", 
                CompoundConfig["DAI"]["cToken"],
                self.notional.getCurrencyAndRates(2)["assetRate"]["rateOracle"],
            ),
            "USDC": self.deployCompEulOracle(
                "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 
                CompoundConfig["USDC"]["cToken"],
                self.notional.getCurrencyAndRates(3)["assetRate"]["rateOracle"],
            )
        }
    
    def deployCompOracle(self, underlying, cToken, rateAdapter):
        return CompoundV2HoldingsOracle.deploy(
            [self.notional, underlying, cToken, rateAdapter],
            {"from": self.deployer}
        )

def main():
    env = PrimeCashOracleEnvironment()