import json
from brownie import interface, Contract
from scripts.arbitrum.arb_config import ListedTokens

def main():
    tradingModule = Contract.from_abi(
        "Trading Module",
        "0xbf6b9c5608d520469d8c4bd1e24f850497af0bb8",
        interface.ITradingModule.abi
    )
    flashLiquidator = "0xcef77c74c88b6deceaf2e954038e7789a0f1bb33"
    batchBase = {
        "version": "1.0",
        "chainId": "42161",
        "createdAt": 1692567274357,
        "meta": {
            "name": "Transactions Batch",
            "description": "",
            "txBuilderVersion": "1.16.1"
        },
        "transactions": [
            {
                "to": tradingModule.address,
                "value": "0",
                "data": tradingModule.setTokenPermissions.encode_input(
                    flashLiquidator,
                    l["address"],
                    (True, 8, 15)
                ),
                "contractMethod": { "inputs": [], "name": "fallback", "payable": True },
                "contractInputsValues": None
            }

            for (_, l) in ListedTokens.items()
        ]
    }

    json.dump(batchBase, open("batch-liquidator.json", 'w'))
