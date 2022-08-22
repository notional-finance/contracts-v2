from brownie import Contract, cTokenV2Aggregator
from scripts.common import loadContractFromABI, loadContractFromArtifact
from tests.helpers import get_balance_trade_action


class EnvironmentV2:
    def __init__(self, config) -> None:
        self.tokens = {}
        self.ctokens = {}
        self.ethOracles = {}
        self.cTokenOracles = {}
        self.config = config

        # Load notional
        if "notional" in self.config:
            self.notional = loadContractFromABI(
                "NotionalProxy", self.config["notional"], "abi/Notional.json"
            )

        # Load tokens
        tokens = self.config["tokens"]
        for k, v in tokens.items():
            self.tokens[k] = loadContractFromABI(k, v["address"], "abi/ERC20.json")
            if k != "WETH":
                self.ethOracles[k] = v["oracle"]

        # Load compound
        ctokens = self.config["compound"]["ctokens"]
        for k, v in ctokens.items():
            if k == "ETH":
                path = "scripts/compound_artifacts/nCEther.json"
            else:
                path = "scripts/compound_artifacts/nCErc20.json"
            self.ctokens[k] = loadContractFromArtifact("c{}".format(k), v["address"], path)
            self.cTokenOracles[k] = Contract.from_abi(
                "c{}Oracle".format(k), v["oracle"], cTokenV2Aggregator.abi
            )

        if "note" in self.config:
            self.note = loadContractFromABI("NoteProxy", self.config["note"], "abi/NoteERC20.json")

    def depositAndLend(
        self, account, currencyId, underlying, depositAmount, market, lendAmount, slippage=0
    ):
        lendAction = [
            {
                "tradeActionType": "Lend",
                "marketIndex": market,
                "notional": lendAmount,
                "minSlippage": slippage,
            }
        ]
        value = depositAmount if currencyId == 1 else 0
        self.notional.batchBalanceAndTradeAction(
            account,
            [
                get_balance_trade_action(
                    currencyId,
                    "DepositUnderlying" if underlying else "DepositAsset",
                    lendAction,
                    depositActionAmount=depositAmount,
                    withdrawEntireCashBalance=True,
                )
            ],
            {"from": account, "value": value},
        )


# def main():
#     with open("v2.{}.json".format(network.show_active()), "r") as f:
#         config = json.load(f)
#     env = EnvironmentV2(config)
