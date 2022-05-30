import json

from brownie import ZERO_ADDRESS
from scripts.common import CurrencySymbol, TokenType, encodeNTokenParams, hasTransferFee
from scripts.environment_v2 import EnvironmentV2
from tests.helpers import get_balance_action


class NotionalInitializer:
    def __init__(self, network, deployer, dryRun=True, config=None, persist=True) -> None:
        self.config = config
        if self.config is None:
            self.config = {}
        self.persist = persist
        self.network = network
        if self.network == "hardhat-fork" or self.network == "mainnet-fork":
            self.network = "mainnet"
            self.persist = False
        self.dryRun = dryRun
        self.deployer = deployer
        self._load()

    def _load(self):
        if self.config is None:
            with open("v2.{}.json".format(self.network), "r") as f:
                self.config = json.load(f)
        self.env = EnvironmentV2(self.config)

    def _save(self):
        print("Saving Notional init data")
        if self.persist:
            with open("v2.{}.json".format(self.network), "w") as f:
                json.dump(self.config, f, sort_keys=True, indent=4)

    def _listCurrency(self, symbol, config):
        if symbol not in self.env.ethOracles:
            raise Exception("{} not found in ethOracles".format(symbol))

        if symbol == "NOMINT":
            if symbol not in self.env.tokens:
                raise Exception("{} not found in tokens".format(symbol))
            address = self.env.tokens[symbol].address
            decimals = self.env.tokens[symbol].decimals()
            asset = (address, hasTransferFee(symbol), TokenType["NonMintable"], decimals)
            underlying = (ZERO_ADDRESS, False, 0, 0, 0)
        else:
            if symbol not in self.env.tokens:
                raise Exception("{} not found in tokens".format(symbol))
            if symbol not in self.env.ctokens:
                raise Exception("{} not found in ctokens".format(symbol))
            assetAddress = self.env.ctokens[symbol].address
            assetDecimals = self.env.ctokens[symbol].decimals()
            underlyingAddress = self.env.tokens[symbol].address
            underlyingDecimals = self.env.tokens[symbol].decimals()
            asset = (assetAddress, hasTransferFee(symbol), TokenType["cToken"], assetDecimals, 0)
            underlying = (
                underlyingAddress,
                hasTransferFee(symbol),
                TokenType["UnderlyingToken"],
                underlyingDecimals,
                0,
            )

        print("Listing currency {}".format(symbol))
        if not self.dryRun:
            self.env.notional.listCurrency(
                asset,
                underlying,
                self.env.ethOracles[symbol],
                False,
                config["buffer"],
                config["haircut"],
                config["liquidationDiscount"],
                {"from": self.deployer},
            )

    def _enableCashGroup(self, currencyId, symbol, config):
        if symbol == "NOMINT":
            assetRateAddress = ZERO_ADDRESS
        else:
            assetRateAddress = self.env.cTokenOracles[symbol].address

        print("Enabling CashGroup for {}".format(symbol))
        if not self.dryRun:
            self.env.notional.enableCashGroup(
                currencyId,
                assetRateAddress,
                (
                    config["maxMarketIndex"],
                    config["rateOracleTimeWindow"],
                    config["totalFee"],
                    config["reserveFeeShare"],
                    config["debtBuffer"],
                    config["fCashHaircut"],
                    config["settlementPenalty"],
                    config["liquidationfCashDiscount"],
                    config["liquidationDebtBuffer"],
                    config["tokenHaircut"][0 : config["maxMarketIndex"]],
                    config["rateScalar"][0 : config["maxMarketIndex"]],
                ),
                self.env.tokens[symbol].name() if symbol != "ETH" else "Ether",
                symbol,
                {"from": self.deployer},
            )

    def enableCurrency(self, currencyId, config):
        symbol = CurrencySymbol[currencyId]
        try:
            self.env.notional.getCurrency(currencyId)
            print("Currency {} ({}) is already listed".format(currencyId, symbol))
        except Exception:
            # List new currency if getCurrency reverts
            self._listCurrency(symbol, config[symbol])

        try:
            # Check if CashGroup is enabled
            self.env.notional.nTokenAddress(currencyId)
            print("CashGroup {} ({}) is already enabled".format(currencyId, symbol))
        except Exception:
            # Enable CashGroup if nTokenAddress reverts
            self._enableCashGroup(currencyId, symbol, config[symbol])

    def _updateDepositParameters(self, currencyId, config):
        current = self.env.notional.getDepositParameters(currencyId)
        modified = False
        for i, v in enumerate(config):
            for j, vv in enumerate(v):
                if current[i][j] != vv:
                    modified = True
                    break

        if not modified:
            print("Deposit parameters are already set for currency {}".format(currencyId))
            return

        print("Updating deposit parameters for {}".format(currencyId))
        if not self.dryRun:
            self.env.notional.updateDepositParameters(currencyId, *config, {"from": self.deployer})

    def _updateInitializationParameters(self, currencyId, config):
        modified = False
        try:
            current = self.env.notional.getInitializationParameters.call(currencyId)
            for i, v in enumerate(config):
                for j, vv in enumerate(v):
                    if current[i][j] != vv:
                        modified = True
                        break
        except Exception:
            # Not intialized yet
            modified = True

        if not modified:
            print("Initialization parameters are already set for currency {}".format(currencyId))
            return

        print("Updating initialization parameters for {}".format(currencyId))
        if not self.dryRun:
            self.env.notional.updateInitializationParameters(
                currencyId, *config, {"from": self.deployer}
            )

    def _updateTokenCollateralParameters(self, currencyId, config):
        modified = False
        current = self.env.notional.getNTokenAccount(self.env.notional.nTokenAddress(currencyId))

        if current[4] != encodeNTokenParams(config):
            modified = True

        if not modified:
            print("Collateral parameters are already set for currency {}".format(currencyId))
            return

        print("Updating collateral parameters for {}".format(currencyId))
        if not self.dryRun:
            self.env.notional.updateTokenCollateralParameters(
                currencyId, *config, {"from": self.deployer}
            )

    def _updateIncentiveEmissionRate(self, currencyId, incentiveRate):
        modified = False
        current = self.env.notional.getNTokenAccount(self.env.notional.nTokenAddress(currencyId))
        if current[2] != incentiveRate:
            modified = True

        if not modified:
            print("Incentive emission rate is already set for currency {}".format(currencyId))
            return

        print("Updating incentive emission rate for {}".format(currencyId))
        if not self.dryRun:
            self.env.notional.updateIncentiveEmissionRate(
                currencyId, incentiveRate, {"from": self.deployer}
            )

    def updateGovParameters(self, currencyId, nTokenConfig, currencyConfig):
        symbol = CurrencySymbol[currencyId]
        self._updateDepositParameters(currencyId, nTokenConfig[symbol]["Deposit"])
        self._updateInitializationParameters(currencyId, nTokenConfig[symbol]["Initialization"])
        self._updateTokenCollateralParameters(currencyId, nTokenConfig[symbol]["Collateral"])
        self._updateIncentiveEmissionRate(
            currencyId, currencyConfig[symbol]["incentiveEmissionRate"]
        )

    def _depositLiquidity(self, currencyId, amount):
        print("Depositing liquidity for currency {}".format(currencyId))
        value = amount if currencyId == 1 else 0
        self.env.notional.batchBalanceAction(
            self.deployer,
            [
                get_balance_action(
                    currencyId, "DepositUnderlyingAndMintNToken", depositActionAmount=amount
                )
            ],
            {"from": self.deployer, "value": value},
        )

    def initializeMarkets(self, currencyId, initialLiquidity):
        # Check if market is already initialized
        balance = self.env.notional.getAccountBalance(currencyId, self.deployer)
        if balance[1] == 0:
            if currencyId != 1:
                symbol = CurrencySymbol[currencyId]
                # Approve Notional contract if necessary
                allowance = self.env.tokens[symbol].allowance(
                    self.deployer, self.env.notional.address
                )
                if allowance == 0:
                    self.env.tokens[symbol].approve(
                        self.env.notional.address, 2 ** 255, {"from": self.deployer}
                    )
            self._depositLiquidity(currencyId, initialLiquidity)

        try:
            self.env.notional.initializeMarkets.call(currencyId, True, {"from": self.deployer})
            print("Initializing market for currency {}".format(currencyId))
            if not self.dryRun:
                self.env.notional.initializeMarkets(currencyId, True, {"from": self.deployer})
            print("Successfully initialized markets for currency {}".format(currencyId))
        except Exception:
            print("Markets are already initialized for currency {}".format(currencyId))
