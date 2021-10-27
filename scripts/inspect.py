# flake8: noqa
import json

from brownie import GovernorAlpha, NoteERC20, Router, network
from brownie.network.contract import Contract
from brownie.project import ContractsVProject
from tests.constants import DEPOSIT_ACTION_TYPE, TRADE_ACTION_TYPE


def main():
    networkName = network.show_active()
    output_file = "v2.{}.json".format(networkName)
    addresses = None
    with open(output_file, "r") as f:
        addresses = json.load(f)

    notionalInterfaceABI = ContractsVProject._build.get("NotionalProxy")["abi"]
    notional = Contract.from_abi("Notional", addresses["notional"], abi=notionalInterfaceABI)
    governance = GovernorAlpha.at(addresses["governor"])
    note = NoteERC20.at(addresses["note"])
    router = Contract.from_abi("Router", addresses["notional"], abi=Router.abi)
