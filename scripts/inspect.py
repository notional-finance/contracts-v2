# flake8: noqa
import json

from brownie import GovernorAlpha, NoteERC20, Router, network
from brownie.network.contract import Contract
from brownie.project import ContractsV2Project
from tests.constants import DEPOSIT_ACTION_TYPE, TRADE_ACTION_TYPE


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
        router.cETH(),
        router.TREASURY(),
        router.CALCULATION_VIEWS(),
        router.VAULT_ACCOUNT_ACTION(),
        router.VAULT_ACTION(),
    ]


def main():
    networkName = network.show_active()
    if networkName == "mainnet-fork" or networkName == 'mainnet-current':
        networkName = "mainnet"
    if networkName == "goerli-fork":
        networkName = "goerli"
    output_file = "v2.{}.json".format(networkName)
    addresses = None
    with open(output_file, "r") as f:
        addresses = json.load(f)

    notionalInterfaceABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
    notional = Contract.from_abi("Notional", addresses["notional"], abi=notionalInterfaceABI)
    governance = GovernorAlpha.at(addresses["governor"])
    note = NoteERC20.at(addresses["note"])
    router = Contract.from_abi("Router", addresses["notional"], abi=Router.abi)
