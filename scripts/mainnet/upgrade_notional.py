import json
import re

from brownie import Contract, Router, accounts, network
from brownie.project import ContractsV2Project
from scripts.deployment import deployNotionalContracts
from scripts.mainnet.deploy_notional import TokenConfig, etherscan_verify, verify

ROUTER_ARG_POSITION = {
    "GovernanceAction": 0,
    "Views": 1,
    "InitializeMarketsAction": 2,
    "nTokenAction": 3,
    "BatchAction": 4,
    "AccountAction": 5,
    "ERC1155Action": 6,
    "LiquidateCurrencyAction": 7,
    "LiquidatefCashAction": 8,
    "cETH": 9,
    "TreasuryAction": 10,
}


def full_upgrade(deployer, verify=True):
    networkName = network.show_active()
    if networkName == "hardhat-fork" or networkName == "mainnet-fork":
        networkName = "mainnet"

    (router, pauseRouter, contracts) = deployNotionalContracts(
        deployer,
        cETH=TokenConfig[networkName]["cETH"],
        WETH=TokenConfig[networkName]["WETH"],
        Comptroller=TokenConfig[networkName]["Comptroller"],
    )

    if verify:
        etherscan_verify(contracts, router, pauseRouter)

    return (router, pauseRouter, contracts)


def update_contract(deployer, output, upgradeContracts):
    router = Contract.from_abi("router", output["notional"], Router.abi)
    routerArgs = [
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
    ]

    contracts = {}
    for c in upgradeContracts:
        print("Deploying {}".format(c))
        contracts[c] = ContractsV2Project[c].deploy({"from": deployer})

        if not hasattr(contracts[c], "address"):
            # Sometimes this is not decoded to a contract container and is just a txn receipt
            contracts[c] = ContractsV2Project[c].at(contracts[c].contract_address)

        # Libraries are not added to the router arguments
        if c in ROUTER_ARG_POSITION:
            routerArgs[ROUTER_ARG_POSITION[c]] = contracts[c].address

    newRouter = Router.deploy(*routerArgs, {"from": deployer})
    etherscan_verify(contracts, None, None)
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

    router = update_contract(
        deployer,
        output,
        [
            "nTokenRedeemAction",
            "AccountAction",
            "BatchAction",
            "InitializeMarketsAction",
            "ERC1155Action",
        ],
    )

    print("New Router Implementation At: ", router.address)
