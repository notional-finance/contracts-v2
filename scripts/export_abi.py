import json

from brownie.project import ContractsV2Project


def main():
    NotionalABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
    with open("abi/Notional.json", "w") as f:
        json.dump(NotionalABI, f, sort_keys=True, indent=4)

    StrategyVaultABI = ContractsV2Project._build.get("IStrategyVault")["abi"]
    with open("abi/IStrategyVault.json", "w") as f:
        json.dump(StrategyVaultABI, f, sort_keys=True, indent=4)
