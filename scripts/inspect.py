# flake8: noqa
import json
from brownie import NoteERC20, Router, network, interface
from brownie.network.contract import Contract
from tests.helpers import get_balance_action, get_balance_trade_action

def get_router_args(router):
    return [
        router.GOVERNANCE(),
        router.VIEWS(),
        router.INITIALIZE_MARKET(),
        router.NTOKEN_ACTIONS(),
        router.BATCH_ACTION(),
        router.ACCOUNT_ACTION(),
        router.ERC1155(),
        router.LIQUIDATE_CURRENCY(),
        router.LIQUIDATE_FCASH(),
        router.TREASURY(),
        router.CALCULATION_VIEWS(),
        router.VAULT_ACCOUNT_ACTION(),
        router.VAULT_ACTION(),
        router.VAULT_LIQUIDATION_ACTION(),
        router.VAULT_ACCOUNT_HEALTH(),
    ]

def get_addresses():
    networkName = network.show_active()
    if networkName == "mainnet-fork" or networkName == "mainnet-current":
        networkName = "mainnet"
    if networkName == "arbitrum-fork" or networkName == "arbitrum-current":
        networkName = "arbitrum-one"
    if networkName == "goerli-fork":
        networkName = "goerli"
    output_file = "v3.{}.json".format(networkName)
    addresses = None
    with open(output_file, "r") as f:
        addresses = json.load(f)

    notional = Contract.from_abi("Notional", addresses["notional"], abi=interface.NotionalProxy.abi)
    note = NoteERC20.at(addresses["note"])
    router = Contract.from_abi("Router", addresses["notional"], abi=Router.abi)

    return (addresses, notional, note, router, networkName)

def main():
    (addresses, notional, note, router, networkName) = get_addresses()
