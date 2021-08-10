import json
import re

import scripts.mainnet.deploy_governance as deploy_governance
from brownie import (
    MockAggregator,
    MockCToken,
    MockERC20,
    NoteERC20,
    accounts,
    cTokenAggregator,
    network,
)
from brownie.network.contract import Contract
from scripts.config import CurrencyDefaults
from scripts.deployment import TokenType, deployNotional
from scripts.mainnet.deploy_governance import EnvironmentConfig

TokenConfig = {
    "kovan": {
        "cETH": "0x40575f9Eb401f63f66F4c434248ad83D3441bf61",
        "DAI": {
            "assetToken": (
                "0x4dC87A3D30C4A1B33E4349f02F4c5B1B1eF9A75D",
                False,
                TokenType["cToken"],
            ),
            "underlyingToken": (
                "0x181D62Ff8C0aEeD5Bc2Bf77A88C07235c4cc6905",
                False,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0x990DE64Bb3E1B6D99b1B50567fC9Ccc0b9891A4D",
            "ethOracleMustInvert": False,
        },
        "USDC": {
            "assetToken": (
                "0xf17C5c7240CBc83D3186A9d6935F003e451C5cDd",
                False,
                TokenType["cToken"],
            ),
            "underlyingToken": (
                "0xF503D5cd87d10Ce8172F9e77f76ADE8109037b4c",
                False,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0x0988059AF97c65D6a6EB8AcA422784728d907406",
            "ethOracleMustInvert": False,
        },
        "USDT": {
            "assetToken": (
                "0xBE2720C0064BF3A0E8F5f83f5B9FaC266c5Ce99E",
                False,
                TokenType["cToken"],
            ),
            # USDT potentially has a transfer fee
            "underlyingToken": (
                "0x52EDEb260f0cb805d9224d00741a576752F045b7",
                True,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0x799e64CfAC5Feb421CBf76FA759B0672a03bcf71",
            "ethOracleMustInvert": False,
        },
        "WBTC": {
            "assetToken": (
                "0xA8E51e20985E926dE882EE700eC7F7d51D89D130",
                False,
                TokenType["cToken"],
            ),
            "underlyingToken": (
                "0x45a8451ceaae5976b4ae5f14a7ad789fae8e9971",
                False,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0x0CB9a95789929dC75D1B77A916762Bc719305543",
            "ethOracleMustInvert": False,
        },
    },
    "mainnet": {
        "cETH": "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5",
        "DAI": {
            "assetToken": (
                "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",
                False,
                TokenType["cToken"],
            ),
            "underlyingToken": (
                "0x6B175474E89094C44Da98b954EedeAC495271d0F",
                False,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0x773616E4d11A78F511299002da57A0a94577F1f4",
            "ethOracleMustInvert": False,
        },
        "USDC": {
            "assetToken": (
                "0x39aa39c021dfbae8fac545936693ac917d5e7563",
                False,
                TokenType["cToken"],
            ),
            "underlyingToken": (
                "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                False,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0x986b5E1e1755e3C2440e960477f25201B0a8bbD4",
            "ethOracleMustInvert": False,
        },
        "USDT": {
            "assetToken": (
                "0xf650c3d88d12db855b8bf7d11be6c55a4e07dcc9",
                False,
                TokenType["cToken"],
            ),
            # USDT potentially has a transfer fee
            "underlyingToken": (
                "0xdAC17F958D2ee523a2206206994597C13D831ec7",
                True,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0xEe9F2375b4bdF6387aa8265dD4FB8F16512A1d46",
            "ethOracleMustInvert": False,
        },
        "WBTC": {
            "assetToken": (
                "0xC11b1268C1A384e55C48c2391d8d480264A3A7F4",
                False,
                TokenType["cToken"],
            ),
            "underlyingToken": (
                "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
                False,
                TokenType["UnderlyingToken"],
            ),
            "ethOracle": "0xdeb288F737066589598e9214E782fa5A8eD689e8",
            "ethOracleMustInvert": False,
        },
    },
}

# Currency Config will inherit CurrencyDefaults except where otherwise specified
CurrencyConfig = {
    "ETH": {
        **CurrencyDefaults,
        **{
            "name": "Ether",
            "buffer": 130,
            "haircut": 70,
            "liquidationDiscount": 108,
            "tokenHaircut": (95, 90),
            "rateScalar": (21, 21),
        },
    },
    "DAI": {
        **CurrencyDefaults,
        **{
            "name": "Dai Stablecoin",
            "maxMarketIndex": 3,
            "buffer": 105,
            "haircut": 95,
            "liquidationDiscount": 104,
            "tokenHaircut": (95, 90, 87),
            "rateScalar": (21, 21, 21),
        },
    },
    "USDC": {
        **CurrencyDefaults,
        **{
            "name": "USD Coin",
            "maxMarketIndex": 3,
            "buffer": 105,
            "haircut": 95,
            "liquidationDiscount": 104,
            "tokenHaircut": (95, 90, 87),
            "rateScalar": (21, 21, 21),
        },
    },
    "WBTC": {
        **CurrencyDefaults,
        **{
            "name": "Wrapped BTC",
            "buffer": 130,
            "haircut": 70,
            "liquidationDiscount": 110,
            "tokenHaircut": (95, 90),
            "rateScalar": (21, 21),
        },
    },
    "USDT": {
        **CurrencyDefaults,
        **{
            "name": "Tether USD",
            "maxMarketIndex": 3,
            "buffer": 105,
            "haircut": 0,
            "liquidationDiscount": 104,
            "tokenHaircut": (95, 90, 87),
            "rateScalar": (21, 21, 21),
        },
    },
}

nTokenCryptoAssetConfig = {
    "Deposit": [
        # Deposit shares
        [int(0.5e8), int(0.5e8)],
        # Leverage thresholds
        [int(0.75e9), int(0.75e9)],
    ],
    "Initialization": [
        # Rate anchors
        [int(1.01e9), int(1.01e9)],
        # Target proportion
        [int(0.5e9), int(0.5e9)],
    ],
    "Collateral": [
        20,  # residual purchase incentive bps
        85,  # pv haircut
        24,  # time buffer hours
        60,  # cash withholding
        92,  # liquidation haircut percentage
    ],
}

nTokenStablecoinConfig = {
    "Deposit": [
        # Deposit shares
        [int(0.25e8), int(0.25e8), int(0.5e8)],
        # Leverage thresholds
        [int(0.78e9), int(0.79e9), int(0.79e9)],
    ],
    "Initialization": [
        # Rate anchors
        [int(1.02e9), int(1.02e9), int(1.02e9)],
        # Target proportion
        [int(0.5e9), int(0.5e9), int(0.5e9)],
    ],
    "Collateral": [
        20,  # residual purchase incentive bps
        85,  # pv haircut
        24,  # time buffer hours
        80,  # cash withholding
        92,  # liquidation haircut percentage
    ],
}

nTokenConfig = {
    "ETH": nTokenCryptoAssetConfig,
    "DAI": nTokenStablecoinConfig,
    "USDC": nTokenStablecoinConfig,
    "WBTC": nTokenCryptoAssetConfig,
    "USDT": nTokenStablecoinConfig,
}


def listCurrency(notional, deployer, symbol):
    networkName = network.show_active()
    if symbol == "ETH":
        currencyId = 1
        assetRateAggregator = cTokenAggregator.deploy(
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

        assetRateAggregator = cTokenAggregator.deploy(
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
                "assetToken": (cDAI.address, False, TokenType["cToken"]),
                "underlyingToken": (DAI.address, False, TokenType["UnderlyingToken"]),
                "ethOracle": ethDaiOracle.address,
                "ethOracleMustInvert": False,
            },
        }

    print("Confirming that NOTE token is hardcoded properly in Constants.sol")
    with open("contracts/global/Constants.sol") as f:
        constants = f.read()
        m = re.search("address constant NOTE_TOKEN_ADDRESS = (.*);", constants)
        assert m.group(1) == output["note"]

    (pauseRouter, router, proxy, notional) = deployNotional(
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

    if network.show_active() == "development":
        # NOTE: Activate notional needs to be called via the guardian
        noteERC20 = Contract.from_abi("NOTE", output["note"], abi=NoteERC20.abi)
        noteERC20.activateNotional(notional.address, {"from": accounts[0]})

        # Test to see if this method reverts or not
        noteERC20.getCurrentVotes(deployer)

    with open(output_file, "w") as f:
        output["notional"] = notional.address
        json.dump(output, f, sort_keys=True, indent=4)


# Etherscan Verify:
#
# Transaction sent: 0x5ba1f5e87be3d7fb1602f8d54f335687f7d36639fe60ffd1987ca5d867ac708e
#   Gas price: 1.0 gwei   Gas limit: 2795051   Nonce: 31
#   SettleAssetsExternal.constructor confirmed   Block: 26703486   Gas used: 2540956 (90.91%)
#   SettleAssetsExternal deployed at: 0x923ABfd03D76990793bc0dfBA299ae67FAe5C0b5

# Transaction sent: 0xf2d54aea8aca31bceba44331a87fb477f64f18d3a40a528f2740aae3526d1d01
#   Gas price: 1.0 gwei   Gas limit: 3963719   Nonce: 32
#   FreeCollateralExternal.constructor confirmed   Block: 26703488   Gas used: 3603381 (90.91%)
#   FreeCollateralExternal deployed at: 0xB06c0881265140Cfd2f6510A95e04Dca8Df4405B

# Transaction sent: 0x9857e698115de67ab2581b0b1f3f86b90c174d690e29ecffa81b1b5f6f076adf
#   Gas price: 1.0 gwei   Gas limit: 5605458   Nonce: 33
#   TradingAction.constructor confirmed   Block: 26703490   Gas used: 5095871 (90.91%)
#   TradingAction deployed at: 0x616D2BbC77Dfe613d6fD51f34C3c68Ca733F8F41

# Transaction sent: 0xccf75be436bbddbe26428a6a1ff449718ec1c9edbb13054b5d134795e7a347c0
#   Gas price: 1.0 gwei   Gas limit: 4330978   Nonce: 34
#   nTokenMintAction.constructor confirmed   Block: 26703492   Gas used: 3937253 (90.91%)
#   nTokenMintAction deployed at: 0x94fdaa2B18BeBe9bB6585FcC3152Cf5f685E3642

# Transaction sent: 0x9a01ad84bdc7fae334408e6e7339c09636fe7d709f7088af3168b49c4458472f
#   Gas price: 1.0 gwei   Gas limit: 4586085   Nonce: 35
#   GovernanceAction.constructor confirmed   Block: 26703494   Gas used: 4169169 (90.91%)
#   TODO: does not verify...
#   GovernanceAction deployed at: 0xA440a18177a7278A5035cdb77D5b26C3B1585423

# Transaction sent: 0xa765628ac0e8a23441d2621c83f7f9dcffbbb3a1a4084c23714a8c9960d94b10
#   Gas price: 1.0 gwei   Gas limit: 5567491   Nonce: 36
#   Views.constructor confirmed   Block: 26703496   Gas used: 5061356 (90.91%)
#   Views deployed at: 0x362bB710930A7f3D84aa04D2Ab827F4FDeB5B9cF

# Transaction sent: 0xfe06e6c3a3778774142efcdcfa03e9ee2b49fbd6a3cfd4e0d7bf5f252a0c8e2f
#   Gas price: 1.0 gwei   Gas limit: 5343683   Nonce: 37
#   InitializeMarketsAction.constructor confirmed   Block: 26703497   Gas used: 4857894 (90.91%)
#   InitializeMarketsAction deployed at: 0xa1C3C49CBA231C2181CE99095E686f1A0b4Bb485

# Transaction sent: 0x756c6f231fcbc0d5da5297c3c7cdb49d633d82bcdffb43d95b6cf9f93d8e0ef4
#   Gas price: 1.0 gwei   Gas limit: 5753591   Nonce: 38
#   nTokenRedeemAction.constructor confirmed   Block: 26703499   Gas used: 5230538 (90.91%)
#   nTokenRedeemAction deployed at: 0xB5b889CFa3EDd5257C2334DdacfECBB5784C0d82

# Transaction sent: 0xa8811a7ee44caec1b61d3355c8516b29f5319626abb07d0708046cf7fe50bb2b
#   Gas price: 1.0 gwei   Gas limit: 4348352   Nonce: 39
#   nTokenAction.constructor confirmed   Block: 26703501   Gas used: 3953048 (90.91%)
#   nTokenAction deployed at: 0xf1Eb7FA39621cfE74dC42162cAA2520bfc033e80

# Transaction sent: 0xc0ddfff3f2eed330d04dab5fe0e69f34cd3cfaabf215c12dd8e2c6e070b27bfe
#   Gas price: 1.0 gwei   Gas limit: 4215795   Nonce: 40
#   BatchAction.constructor confirmed   Block: 26703503   Gas used: 3832541 (90.91%)
#   BatchAction deployed at: 0x7b3a61e06a6c7d66103519F011b9bb3f055A9Ccb

# Transaction sent: 0x575f36c8d46e3e551d7268feb5d95dac358b9a940ce54230eb73bbe4698ee626
#   Gas price: 1.0 gwei   Gas limit: 2346213   Nonce: 41
#   AccountAction.constructor confirmed   Block: 26703505   Gas used: 2132921 (90.91%)
#   AccountAction deployed at: 0x0060802Bf69DEc318376d39E3936FE3cf157414D

# Transaction sent: 0x132c3bdcf6a388aafd8fdeb960b20ff00fcedbd6ba4c83782e23c5b6b3519f3a
#   Gas price: 1.0 gwei   Gas limit: 3502304   Nonce: 42
#   ERC1155Action.constructor confirmed   Block: 26703506   Gas used: 3183913 (90.91%)
#   ERC1155Action deployed at: 0x039C0ff7a7892Af483Be14a5e0945542e2C5919C

# Transaction sent: 0x96a9cfdba32809da8184ef993406c6ede95f79020508514fad905e9440c7bb89
#   Gas price: 1.0 gwei   Gas limit: 4488440   Nonce: 43
#   LiquidateCurrencyAction.constructor confirmed   Block: 26703508   Gas used: 4080400 (90.91%)
#   LiquidateCurrencyAction deployed at: 0xb64c0C4421717AD210b5eCdf93fcBCcad3C5A97a

# Transaction sent: 0x8d04b2d3c8de5b71989e2ba9141f8d153e1def236d68ee07556e20a94e3a8288
#   Gas price: 1.0 gwei   Gas limit: 5888598   Nonce: 44
#   LiquidatefCashAction.constructor confirmed   Block: 26703510   Gas used: 5353271 (90.91%)
#   LiquidatefCashAction deployed at: 0xa3113764D5FBF3d5760232Fb0ead771fD4543522

# Transaction sent: 0x6f95022e8ed717329a1f3371231ec71be116c5d2c8d3376580a87eb828041f62
#   Gas price: 1.0 gwei   Gas limit: 575741   Nonce: 45
#   PauseRouter.constructor confirmed   Block: 26703511   Gas used: 523401 (90.91%)
#   PauseRouter deployed at: 0xB09c0eF2455D2C0ab3ad0652ADf8D61348CA03F7

# Transaction sent: 0xff97983d9f6f9ba9595a3eef0ac41e95b8d4ea3af9d579dc2b8ae738edada1bd
#   Gas price: 1.0 gwei   Gas limit: 976776   Nonce: 46
#   Router.constructor confirmed   Block: 26703513   Gas used: 887979 (90.91%)
#   TODO: source code exceeds 500k chars
#   Router deployed at: 0xA9961D107536B4Ff096a42ca0A9c24aA71D69f8B

# Transaction sent: 0xff9ac23a4e33b181bf557bd444a59c5262bf0215cf9888960342385d1ccbad7f
#   Gas price: 1.0 gwei   Gas limit: 529069   Nonce: 47
#   nProxy.constructor confirmed   Block: 26703515   Gas used: 480972 (90.91%)
#   nProxy deployed at: 0x4B4D336d91a1A703989306D66EAA36D2514165a8

# Transaction sent: 0x8ea3e1e3ee2ed62e47bbfcd58395054562ebae8cc87eb085785d366bb5f859a6
#   Gas price: 1.0 gwei   Gas limit: 522879   Nonce: 48
#   cTokenAggregator.constructor confirmed   Block: 26703517   Gas used: 475345 (90.91%)
#   cTokenAggregator deployed at: 0x826aE66EDf285d6F38FEF1120705D85947d1Ab13


# nToken: 0x9d8b139c1C33E67779d2767b68272DD987Ea1989
