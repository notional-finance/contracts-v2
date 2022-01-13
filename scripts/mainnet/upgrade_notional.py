import json
import re

from brownie import Contract, Router, accounts, network
from scripts.deployment import deployNotionalContracts
from scripts.mainnet.deploy_notional import TokenConfig, etherscan_verify, verify

ROUTER_ARG_POSITION = {
    "Governance": 0,
    "Views": 1,
    "InitializeMarket": 2,
    "nTokenActions": 3,
    "nTokenRedeem": 4,
    "BatchAction": 5,
    "AccountAction": 6,
    "ERC1155": 7,
    "LiquidateCurrency": 8,
    "LiquidatefCash": 9,
    "cETH": 10,
    "TreasuryManager": 11,
}


def full_upgrade(deployer, verify=True):
    networkName = network.show_active()
    if networkName == "hardhat-fork":
        networkName = "mainnet"

    (router, pauseRouter, contracts) = deployNotionalContracts(
        deployer,
        cETH=TokenConfig[networkName]["cETH"],
        WETH=TokenConfig[networkName]["WETH"],
        Comptroller=TokenConfig[networkName]["Comptroller"],
        COMP=TokenConfig[networkName]["COMP"],
    )

    if verify:
        etherscan_verify(contracts, router, pauseRouter)

    return (router, pauseRouter, contracts)


def update_contract(deployer, output):
    router = Contract.from_abi("router", output["notional"], Router.abi)
    routerArgs = [
        router.GOVERNANCE(),
        router.VIEWS(),
        router.INITIALIZE_MARKET(),
        router.NTOKEN_ACTIONS(),
        router.NTOKEN_REDEEM(),
        router.BATCH_ACTION(),
        router.ACCOUNT_ACTION(),
        router.ERC1155(),
        router.LIQUIDATE_CURRENCY(),
        router.LIQUIDATE_FCASH(),
        router.cETH(),
    ]
    # THIS IS FOR KOVAN
    # routerArgs[ROUTER_ARG_POSITION["Governance"]] = "0xfEbC565a1C8C70dBbDC11F0E6Ad8cc33B6F3Dd1B"
    # THIS IS FOR MAINNET
    routerArgs[ROUTER_ARG_POSITION["Governance"]] = "0xD2b104A30518ABeE70E5b77023d8966A2234253d"

    newRouter = Router.deploy(*routerArgs, {"from": deployer})
    verify(newRouter.address, routerArgs)
    return newRouter


def upgrade_checks():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    print("Confirming that NOTE token is hardcoded properly in Constants.sol")
    with open("contracts/global/Constants.sol") as f:
        constants = f.read()
        m = re.search("address constant NOTE_TOKEN_ADDRESS = (.*);", constants)
        assert m.group(1) == output["note"]

    return (deployer, output)
