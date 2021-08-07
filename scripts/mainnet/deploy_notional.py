import json
import os

from brownie import NoteERC20, accounts, network
from scripts.deployment import deployNotional

# NotionalConfig = {
#     "ETH": {
#         "assetToken": (
#             # Address, hasFee, tokenType
#         ),
#         "underlyingToken": (
#             # Address, hasFee, tokenType
#         ),
#         "ethOracle": oracleAddress,
#         "mustInvert": False,
#         "Buffer":
#         "Haircut":
#         "CashGroup": (

#         ),
#         "LiquidationDiscount":
#         "IncentiveRate":
#         "nToken": {
#             "Deposit": []
#             "Initialization": []
#             "Collateral": [],
#         }
#     },
#     "DAI": {

#     },
#     "USDC": {

#     },
#     "WBTC": {

#     },
#     "USDT": {

#     }
# }


def listCurrency(notional, deployer, currency):
    pass


#     txn = notional.listCurrency(
#         (cToken[symbol].address, symbol == "USDT", TokenType["cToken"]),
#         (self.token[symbol].address, symbol == "USDT", TokenType["UnderlyingToken"]),
#         self.ethOracle[symbol].address,
#         False,
#         config["buffer"],
#         config["haircut"],
#         config["liquidationDiscount"],
#     )
#     currencyId = txn.events["ListCurrency"]["newCurrencyId"]
#     assetRateAggregator = cTokenAggregator.deploy(cToken.address, {"from": deployer})

#     notional.enableCashGroup(currencyId, assetRateAggregator.address, settings, name, symbol)
#     notional.updateDepositParameters(currencyId, *(nTokenDefaults["Deposit"]))
#     notional.updateInitializationParameters(currencyId, *(nTokenDefaults["Initialization"]))
#     notional.updateTokenCollateralParameters(currencyId, *(nTokenDefaults["Collateral"]))
#     notional.updateIncentiveEmissionRate(currencyId, CurrencyDefaults["incentiveEmissionRate"])


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    if network.show_active() == "development":
        accounts[0].transfer(deployer, 100e18)

    (pauseRouter, router, proxy, notional) = deployNotional(
        deployer, os.environ["cETH"], os.environ["GUARDIAN_MULTISIG_ADDRESS"]
    )

    # At this point Notional is owned by the deployer. Now will go ahead
    # and set the initial configuration
    listCurrency(notional, deployer, "ETH")
    listCurrency(notional, deployer, "DAI")
    listCurrency(notional, deployer, "USDC")
    listCurrency(notional, deployer, "WBTC")
    listCurrency(notional, deployer, "USDT")

    noteERC20 = NoteERC20(output["note"])
    # Activate notional needs to be called via the guardian
    noteERC20.activateNotional(notional.address, {"from": deployer})

    # Test to see if this method reverts or not
    noteERC20.getCurrentVotes(deployer)

    with open(output_file, "w") as f:
        output["notional"] = notional.address
        json.dump(output, f, sort_keys=True, indent=4)
