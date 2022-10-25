import hashlib
import json
import os

import requests
from brownie import (
    AccountAction,
    BatchAction,
    CalculationViews,
    Contract,
    ERC1155Action,
    InitializeMarketsAction,
    LiquidateCurrencyAction,
    LiquidatefCashAction,
    Router,
    VaultAccountAction,
    VaultAction,
    Views,
    nTokenAction,
)

ETHERSCAN_TOKEN = os.environ["ETHERSCAN_TOKEN"]
ROUTER = "0xD7c3Dc1C36d19cF4e8cea4eA143a2f4458Dd1937"

ETHERSCAN_API = (
    "https://api.etherscan.io/api?module=contract&action=getsourcecode&address={}&apikey={}"
)


def get_contracts(router):
    contracts = {}
    finalRouter = Contract.from_abi("FinalRouter", router, Router.abi)

    contracts["Governance"] = finalRouter.GOVERNANCE()
    contracts["Views"] = finalRouter.VIEWS()
    contracts["InitializeMarket"] = finalRouter.INITIALIZE_MARKET()
    contracts["nTokenActions"] = finalRouter.NTOKEN_ACTIONS()
    contracts["BatchAction"] = finalRouter.BATCH_ACTION()
    contracts["AccountAction"] = finalRouter.ACCOUNT_ACTION()
    contracts["ERC1155"] = finalRouter.ERC1155()
    contracts["LiquidateCurrency"] = finalRouter.LIQUIDATE_CURRENCY()
    contracts["LiquidatefCash"] = finalRouter.LIQUIDATE_FCASH()
    contracts["Treasury"] = finalRouter.TREASURY()
    contracts["CalculationViews"] = finalRouter.CALCULATION_VIEWS()
    contracts["VaultAction"] = finalRouter.VAULT_ACTION()
    contracts["VaultAccountAction"] = finalRouter.VAULT_ACCOUNT_ACTION()

    batchAction = Contract.from_abi("BatchAction", contracts["BatchAction"], BatchAction.abi)
    (
        contracts["FreeCollateral"],
        contracts["MigrateIncentives"],
        contracts["SettleAssets"],
        contracts["TradingAction"],
        contracts["nTokenMint"],
        contracts["nTokenRedeem"],
    ) = batchAction.getLibInfo()

    accountAction = Contract.from_abi("", contracts["AccountAction"], AccountAction.abi)
    (_, _, _, contracts["nTokenRedeem2"]) = accountAction.getLibInfo()

    vaultAction = Contract.from_abi("", contracts["VaultAction"], VaultAction.abi)
    (contracts["TradingActionVault"]) = vaultAction.getLibInfo()

    return contracts


def get_contract_hashes(address, name, existing_hashes):
    resp = requests.get(ETHERSCAN_API.format(address, ETHERSCAN_TOKEN)).json()
    full_output = {}
    hashes = {}
    print("Analyzing {}...".format(name))
    for r in resp["result"]:
        source_code = json.loads(r["SourceCode"][1:-1])

        for (c, source) in source_code["sources"].items():
            encoded = source["content"].replace("\r", "")
            source_code["sources"][c]["content"] = encoded
            hash_output = hashlib.sha1(encoded.encode("utf8")).hexdigest()
            hashes[c] = hash_output

            if (
                c.startswith("interfaces")
                or c.startswith("@openzeppelin")
                or c == "contracts/global/Types.sol"
            ):
                pass
            elif c not in existing_hashes:
                print("😔 {} not found".format(c))
            elif existing_hashes[c] == hash_output:
                print("✅ {} matches".format(c))
            else:
                print("💀 {} error".format(c))

        full_output[r["ContractName"]] = {
            "SourceCode": source_code,
            "ConstructorArguments": r["ConstructorArguments"],
        }


def build_existing_hashes():
    hashes = {}
    for root, dirs, files in os.walk("./build"):
        if root.startswith("./build/deployments"):
            continue
        if root.startswith("./build/interfaces"):
            continue
        for name in files:
            if name == "tests.json":
                continue
            if name.endswith(".json"):
                print(os.path.join(root, name))
                with open(os.path.join(root, name), "r") as f:
                    data = json.load(f)
                    hashes[data["sourcePath"]] = hashlib.sha1(
                        data["source"].encode("utf8")
                    ).hexdigest()

    return hashes


def validate_libs(contracts):
    print("Validating Libraries...\n")

    c = Contract.from_abi("", contracts["Views"], Views.abi)
    assert (contracts["FreeCollateral"], contracts["MigrateIncentives"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["InitializeMarket"], InitializeMarketsAction.abi)
    assert (contracts["nTokenMint"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["nTokenActions"], nTokenAction.abi)
    assert (
        contracts["FreeCollateral"],
        contracts["MigrateIncentives"],
        contracts["SettleAssets"],
    ) == c.getLibInfo()

    c = Contract.from_abi("", contracts["BatchAction"], BatchAction.abi)
    assert (
        contracts["FreeCollateral"],
        contracts["MigrateIncentives"],
        contracts["SettleAssets"],
        contracts["TradingAction"],
        contracts["nTokenMint"],
        contracts["nTokenRedeem"],
    ) == c.getLibInfo()

    c = Contract.from_abi("", contracts["AccountAction"], AccountAction.abi)
    assert (
        contracts["FreeCollateral"],
        contracts["MigrateIncentives"],
        contracts["SettleAssets"],
        contracts["nTokenRedeem2"],
    ) == c.getLibInfo()

    c = Contract.from_abi("", contracts["ERC1155"], ERC1155Action.abi)
    assert (contracts["FreeCollateral"], contracts["SettleAssets"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["LiquidateCurrency"], LiquidateCurrencyAction.abi)
    assert (contracts["FreeCollateral"], contracts["MigrateIncentives"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["LiquidatefCash"], LiquidatefCashAction.abi)
    assert (contracts["FreeCollateral"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["CalculationViews"], CalculationViews.abi)
    assert (contracts["MigrateIncentives"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["VaultAccountAction"], VaultAccountAction.abi)
    assert (contracts["TradingActionVault"]) == c.getLibInfo()

    c = Contract.from_abi("", contracts["VaultAction"], VaultAction.abi)
    assert (contracts["TradingActionVault"]) == c.getLibInfo()


def main():
    # with open("existing_hashes.json", "r") as f:
    #     existing_hashes = json.load(f)

    # with open("contracts.json", "r") as f:
    #     contracts = json.load(f)
    contracts = get_contracts(ROUTER)
    existing_hashes = build_existing_hashes()

    validate_libs(contracts)

    get_contract_hashes(ROUTER, "new_router", existing_hashes)

    for (name, address) in contracts.items():
        if name in ["VaultAction", "VaultAccountAction", "AccountAction"]:
            get_contract_hashes(address, name, existing_hashes)
        else:
            pass
