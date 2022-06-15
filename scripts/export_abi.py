import json

from brownie.project import ContractsV2Project


def main():
    NotionalABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
    with open("abi/Notional.json", "w") as f:
        json.dump(NotionalABI, f, sort_keys=True, indent=4)
