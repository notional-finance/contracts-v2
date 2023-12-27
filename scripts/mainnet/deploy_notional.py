import json
import re
import subprocess

import scripts.mainnet.deploy_governance as deploy_governance
from brownie import (
    MockAggregator, 
    MockCToken, 
    MockERC20, 
    accounts, 
    cTokenLegacyAggregator, 
    cTokenV2Aggregator, 
    network
)
from scripts.deployment import TokenType, deployNotional
from scripts.mainnet.deploy_governance import EnvironmentConfig

CTOKEN_DECIMALS = 8

TokenConfig = {
    "kovan": {
        "cETH": "0x40575f9Eb401f63f66F4c434248ad83D3441bf61",
        "WETH": "0xd0a1e359811322d97991e03f863a0c30c2cf029c",
        "Comptroller": "0x2D5D30a561278a5F0ad8779A386dAA4C478865D0",
        "DAI": {
            "assetToken": (
                "0x4dC87A3D30C4A1B33E4349f02F4c5B1B1eF9A75D",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            "underlyingToken": (
                "0x181D62Ff8C0aEeD5Bc2Bf77A88C07235c4cc6905",
                False,
                TokenType["UnderlyingToken"],
                18,
                0,
            ),
            "ethOracle": "0x990DE64Bb3E1B6D99b1B50567fC9Ccc0b9891A4D",
            "ethOracleMustInvert": False,
        },
        "USDC": {
            "assetToken": (
                "0xf17C5c7240CBc83D3186A9d6935F003e451C5cDd",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            "underlyingToken": (
                "0xF503D5cd87d10Ce8172F9e77f76ADE8109037b4c",
                False,
                TokenType["UnderlyingToken"],
                6,
                0,
            ),
            "ethOracle": "0x0988059AF97c65D6a6EB8AcA422784728d907406",
            "ethOracleMustInvert": False,
        },
        "USDT": {
            "assetToken": (
                "0xBE2720C0064BF3A0E8F5f83f5B9FaC266c5Ce99E",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            # USDT potentially has a transfer fee
            "underlyingToken": (
                "0x52EDEb260f0cb805d9224d00741a576752F045b7",
                True,
                TokenType["UnderlyingToken"],
                6,
                0,
            ),
            "ethOracle": "0x799e64CfAC5Feb421CBf76FA759B0672a03bcf71",
            "ethOracleMustInvert": False,
        },
        "WBTC": {
            "assetToken": (
                "0xA8E51e20985E926dE882EE700eC7F7d51D89D130",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            "underlyingToken": (
                "0x45a8451ceaae5976b4ae5f14a7ad789fae8e9971",
                False,
                TokenType["UnderlyingToken"],
                8,
                0,
            ),
            "ethOracle": "0x0CB9a95789929dC75D1B77A916762Bc719305543",
            "ethOracleMustInvert": False,
        },
    },
    "mainnet": {
        "WETH": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        "Comptroller": "0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B",
        "cETH": "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5",
        "DAI": {
            "assetToken": (
                "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            "underlyingToken": (
                "0x6B175474E89094C44Da98b954EedeAC495271d0F",
                False,
                TokenType["UnderlyingToken"],
                18,
                0,
            ),
            "ethOracle": "0x6085B0a8f4c7ffA2E8CA578037792D6535d1E29B",
            "ethOracleMustInvert": False,
        },
        "USDC": {
            "assetToken": (
                "0x39aa39c021dfbae8fac545936693ac917d5e7563",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            "underlyingToken": (
                "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                False,
                TokenType["UnderlyingToken"],
                6,
                0,
            ),
            "ethOracle": "0x68225F47813aF66F186b3714Ffe6a91850Bc76B4",
            "ethOracleMustInvert": False,
        },
        "WBTC": {
            "assetToken": (
                "0xccF4429DB6322D5C611ee964527D42E5d685DD6a",
                False,
                TokenType["cToken"],
                CTOKEN_DECIMALS,
                0,
            ),
            "underlyingToken": (
                "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
                False,
                TokenType["UnderlyingToken"],
                8,
                0,
            ),
            "ethOracle": "0x10aae34011c256A9E63ab5ac50154C2539c0f51d",
            "ethOracleMustInvert": False,
        },
    },
}

# Currency Config will inherit CurrencyDefaults except where otherwise specified
CurrencyConfig = {
    "ETH": {
        "name": "Ether",
        "buffer": 133,
        "haircut": 75,
        "liquidationDiscount": 108,
        "maxMarketIndex": 2,
        "rateOracleTimeWindow": 72,
        "totalFee": 50,
        "reserveFeeShare": 50,
        "debtBuffer": 200,
        "fCashHaircut": 200,
        "settlementPenalty": 50,
        "liquidationfCashDiscount": 50,
        "liquidationDebtBuffer": 50,
        "tokenHaircut": (95, 90),
        "rateScalar": (18, 18),
        "incentiveEmissionRate": 1_000_000,
    },
    "DAI": {
        "name": "Dai Stablecoin",
        "buffer": 109,
        "haircut": 92,
        "liquidationDiscount": 104,
        "maxMarketIndex": 3,
        "rateOracleTimeWindow": 72,
        "totalFee": 50,
        "reserveFeeShare": 50,
        "debtBuffer": 200,
        "fCashHaircut": 200,
        "settlementPenalty": 50,
        "liquidationfCashDiscount": 50,
        "liquidationDebtBuffer": 50,
        "tokenHaircut": (95, 90, 88),
        "rateScalar": (20, 20, 20),
        "incentiveEmissionRate": 9_000_000,
    },
    "USDC": {
        "name": "USD Coin",
        "buffer": 109,
        "haircut": 92,
        "liquidationDiscount": 104,
        "maxMarketIndex": 3,
        "rateOracleTimeWindow": 72,
        "totalFee": 50,
        "reserveFeeShare": 50,
        "debtBuffer": 200,
        "fCashHaircut": 200,
        "settlementPenalty": 50,
        "liquidationfCashDiscount": 50,
        "liquidationDebtBuffer": 50,
        "tokenHaircut": (95, 90, 88),
        "rateScalar": (20, 20, 20),
        "incentiveEmissionRate": 9_000_000,
    },
    "WBTC": {
        "name": "Wrapped BTC",
        "buffer": 138,
        "haircut": 72,
        "liquidationDiscount": 110,
        "maxMarketIndex": 2,
        "rateOracleTimeWindow": 72,
        "totalFee": 50,
        "reserveFeeShare": 50,
        "debtBuffer": 200,
        "fCashHaircut": 200,
        "settlementPenalty": 50,
        "liquidationfCashDiscount": 50,
        "liquidationDebtBuffer": 50,
        "tokenHaircut": (95, 90),
        "rateScalar": (18, 18),
        "incentiveEmissionRate": 1_000_000,
    },
}

nTokenCryptoAssetConfig = {
    "Deposit": [
        # Deposit shares
        [int(0.4e8), int(0.6e8)],
        # Leverage thresholds
        [int(0.81e9), int(0.81e9)],
    ],
    "Initialization": [
        # Annualized anchor rate
        [int(1), int(1)],
        # Target proportion
        [int(0.54e9), int(0.54e9)],
    ],
    "Collateral": [
        20,  # residual purchase incentive 10 bps
        85,  # pv haircut
        24,  # time buffer hours
        80,  # cash withholding
        94,  # liquidation haircut percentage
        5, # Oracle deviation percentage
    ],
}

nTokenStablecoinConfig = {
    "Deposit": [
        # Deposit shares
        [int(0.25e8), int(0.35e8), int(0.4e8)],
        # Leverage thresholds
        [int(0.80e9), int(0.80e9), int(0.81e9)],
    ],
    "Initialization": [
        # Annualized anchor rate
        [int(0.03e9), int(0.03e9), int(0.03e9)],
        # Target proportion
        [int(0.55e9), int(0.55e9), int(0.55e9)],
    ],
    "Collateral": [
        20,  # residual purchase incentive bps
        80,  # pv haircut
        24,  # time buffer hours
        100,  # cash withholding
        94,  # liquidation haircut percentage
        5, # Oracle deviation percentage
    ],
}

nTokenConfig = {
    "ETH": nTokenCryptoAssetConfig,
    "DAI": nTokenStablecoinConfig,
    "USDC": nTokenStablecoinConfig,
    "WBTC": nTokenCryptoAssetConfig,
}


def listCurrency(notional, deployer, symbol):
    networkName = network.show_active()
    if symbol == "ETH":
        currencyId = 1
        assetRateAggregator = cTokenLegacyAggregator.deploy(
            TokenConfig[networkName]["cETH"], {"from": deployer}
        )
    else:
        print("Listing currency {}".format(symbol))
        txn = notional.listCurrency(
            TokenConfig[networkName][symbol]["assetToken"],
            TokenConfig[networkName][symbol]["underlyingToken"],
            TokenConfig[networkName][symbol]["ethOracle"],
            TokenConfig[networkName][symbol]["ethOracleMustInvert"],
            CurrencyConfig[symbol]["buffer"],
            CurrencyConfig[symbol]["haircut"],
            CurrencyConfig[symbol]["liquidationDiscount"],
            {"from": deployer},
        )
        currencyId = txn.events["ListCurrency"]["newCurrencyId"]
        print("Listed currency {} with id {}".format(symbol, currencyId))

        if symbol == "USDC":
            assetRateAggregator = cTokenLegacyAggregator.deploy(
                TokenConfig[networkName][symbol]["assetToken"][0], {"from": deployer}
            )
        else:
            assetRateAggregator = cTokenV2Aggregator.deploy(
                TokenConfig[networkName][symbol]["assetToken"][0], {"from": deployer}
            )
        print("Deployed cToken aggregator at {}".format(assetRateAggregator.address))

    txn = notional.enableCashGroup(
        currencyId,
        assetRateAggregator.address,
        (
            CurrencyConfig[symbol]["maxMarketIndex"],
            CurrencyConfig[symbol]["rateOracleTimeWindow"],
            CurrencyConfig[symbol]["totalFee"],
            CurrencyConfig[symbol]["reserveFeeShare"],
            CurrencyConfig[symbol]["debtBuffer"],
            CurrencyConfig[symbol]["fCashHaircut"],
            CurrencyConfig[symbol]["settlementPenalty"],
            CurrencyConfig[symbol]["liquidationfCashDiscount"],
            CurrencyConfig[symbol]["liquidationDebtBuffer"],
            CurrencyConfig[symbol]["tokenHaircut"],
            CurrencyConfig[symbol]["rateScalar"],
        ),
        CurrencyConfig[symbol]["name"],
        symbol,
        {"from": deployer},
    )

    notional.updateDepositParameters(
        currencyId, *(nTokenConfig[symbol]["Deposit"]), {"from": deployer}
    )

    notional.updateInitializationParameters(
        currencyId, *(nTokenConfig[symbol]["Initialization"]), {"from": deployer}
    )

    notional.updateTokenCollateralParameters(
        currencyId, *(nTokenConfig[symbol]["Collateral"]), {"from": deployer}
    )

    notional.updateIncentiveEmissionRate(
        currencyId, CurrencyConfig[symbol]["incentiveEmissionRate"], {"from": deployer}
    )


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)

    if network.show_active() == "development":
        deploy_governance.main()

        accounts[0].transfer(deployer, 100e18)
        cETH = MockERC20.deploy("Compound Ether", "cETH", 8, 0, {"from": accounts[0]})
        DAI = MockERC20.deploy("Dai Stablecoin", "DAI", 18, 0, {"from": accounts[0]})
        cDAI = MockCToken.deploy(8, {"from": accounts[0]})
        cDAI.setUnderlying(DAI.address)
        ethDaiOracle = MockAggregator.deploy(18, {"from": accounts[0]})
        ethDaiOracle.setAnswer(0.01e18)
        TokenConfig["development"] = {
            "cETH": cETH.address,
            "DAI": {
                "assetToken": (cDAI.address, False, TokenType["cToken"], CTOKEN_DECIMALS, 0),
                "underlyingToken": (DAI.address, False, TokenType["UnderlyingToken"], 18, 0),
                "ethOracle": ethDaiOracle.address,
                "ethOracleMustInvert": False,
            },
        }

    print("Confirming that NOTE token is hardcoded properly in Deployments.sol")
    with open("contracts/global/Deployments.sol") as f:
        constants = f.read()
        m = re.search("address constant NOTE_TOKEN_ADDRESS = (.*);", constants)
        assert m.group(1) == output["note"]

    (pauseRouter, router, proxy, notional, contracts) = deployNotional(
        deployer,
        TokenConfig[network.show_active()]["cETH"],
        EnvironmentConfig[network.show_active()]["GuardianMultisig"],
    )

    # At this point Notional is owned by the deployer. Now will go ahead
    # and set the initial configuration
    listCurrency(notional, deployer, "ETH")
    listCurrency(notional, deployer, "DAI")

    if network.show_active() != "development":
        listCurrency(notional, deployer, "USDC")
        listCurrency(notional, deployer, "WBTC")

    with open(output_file, "w") as f:
        output["notional"] = notional.address
        json.dump(output, f, sort_keys=True, indent=4)

    if network.show_active() != "development":
        etherscan_verify(contracts, router, pauseRouter)


def etherscan_verify(contracts, router, pauseRouter):
    for (name, contract) in contracts.items():
        print("Verifying {} at {}".format(name, contract.address))
        verify(contract.address, [])

    if pauseRouter:
        print("Verifying Pause Router at {}".format(pauseRouter.address))
        verify(
            pauseRouter.address,
            [
                contracts["Views"].address,
                contracts["LiquidateCurrencyAction"].address,
                contracts["LiquidatefCashAction"].address,
            ],
        )

    if router:
        print("Verifying Router at {}".format(router.address))
        routerArgs = [
            contracts["Governance"].address,
            contracts["Views"].address,
            contracts["InitializeMarketsAction"].address,
            contracts["nTokenAction"].address,
            contracts["BatchAction"].address,
            contracts["AccountAction"].address,
            contracts["ERC1155Action"].address,
            contracts["LiquidateCurrencyAction"].address,
            contracts["LiquidatefCashAction"].address,
            TokenConfig[network.show_active()]["cETH"],
        ]

        print("Using router args: ", routerArgs)
        verify(router.address, routerArgs)


def verify(address, args):
    proc = subprocess.run(
        ["npx", "hardhat", "verify", "--network", network.show_active(), address] + args,
        capture_output=True,
        encoding="utf8",
    )

    print(proc.stdout)
    print(proc.stderr)
