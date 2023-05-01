from brownie import ZERO_ADDRESS

ChainlinkOracles = {
    "ETH/USD": "0x639fe6ab55c921f74e7fac1ee960c0b6293ba612",
    "USDC/USD": "0x50834f3163758fcc1df9973b6e91f0f0f0434ad3",
    "DAI/USD": "0xc5c8e77b397e531b8ec06bfb0048328b30e9ecfb",
    "WBTC/USD": "0xd0c7101eacbb49f3decccc166d238410d6d46d57",
    "FRAX/USD": "0x0809e3d38d1b4214958faf06d8b1b1a2b73f2ab8",
    "stETH/ETH": "0xded2c52b75b24732e9107377b7ba93ec1ffa4baf",
    "wstETH/stETH": "0xb1552c5e96b312d0bf8b554186f846c40614a540"
}

CurrencyDefaults = {
    "sequencerUptimeOracle": "0xfdb631f5ee196f0ed6faa767959853a9f217697d",

    # Cash Group
    "maxMarketIndex": 2,
    "rateOracleTimeWindow": 72,
    "primeRateOracleTimeWindow5Min": 72,
    "maxDiscountFactor": 40,
    "reserveFeeShare": 80,
    "fCashHaircut": 22,
    "debtBuffer": 22,
    "minOracleRate": 20,
    "liquidationfCashDiscount": 6,
    "liquidationDebtBuffer": 6,
    "maxOracleRate": 28,

    # nToken
    "residualPurchaseIncentive": 20,
    "residualPurchaseTimeBufferHours": 24,
    "pvHaircutPercentage": 90,
    'cashWithholdingBuffer10BPS': 20,
    "liquidationHaircutPercentage": 98,
}

ListedTokens = {
    "ETH": CurrencyDefaults | {
        "address": ZERO_ADDRESS,
        "name": "Ether",
        "decimals": 18,

        "buffer": 124,
        "haircut": 81,
        "liquidationDiscount": 106,
        "maxUnderlyingSupply": 10e8,

        # Prime Cash Curve
        "primeCashCurve": {
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 2,
            "kinkRate2": 8,
            "maxRate25BPS": 255,
            "feeRatePercent": 20,
            "minFeeRate5BPS": 10,
            "maxFeeRate25BPS": 160
        },

        # fCash Curve
        "fCashCurves" : [{
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 17,
            "kinkRate2": 51,
            "maxRate25BPS": 120,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }, {
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 20,
            "kinkRate2": 61,
            "maxRate25BPS": 100,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }],

        "proportion": [0.5e9, 0.5e9],
        "depositShare": [0.55e8, 0.45e8],
        "leverageThreshold": [0.7e9, 0.7e9],
    },
    "DAI": CurrencyDefaults | {
        "address": "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1",
        "name": "Dai Stablecoin",
        "decimals": 18,
        "baseOracle": ChainlinkOracles["DAI/USD"],
        "quoteOracle": ChainlinkOracles["ETH/USD"],
        "invertBase": False,
        "invertQuote": False,

        "buffer": 109,
        "haircut": 92,
        "liquidationDiscount": 104,
        "maxUnderlyingSupply": 10_000e8,

        # Prime Cash Curve
        "primeCashCurve": {
            "kinkUtilization1": 10,
            "kinkUtilization2": 80,
            "kinkRate1": 5,
            "kinkRate2": 16,
            "maxRate25BPS": 192,
            "feeRatePercent": 20,
            "minFeeRate5BPS": 10,
            "maxFeeRate25BPS": 80
        },

        # fCash Curve
        "fCashCurves" : [{
            "kinkUtilization1": 15,
            "kinkUtilization2": 80,
            "kinkRate1": 17,
            "kinkRate2": 51,
            "maxRate25BPS": 120,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }, {
            "kinkUtilization1": 15,
            "kinkUtilization2": 80,
            "kinkRate1": 20,
            "kinkRate2": 61,
            "maxRate25BPS": 100,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }],

        "proportion": [0.5e9, 0.5e9],
        "depositShare": [0.55e8, 0.45e8],
        "leverageThreshold": [0.8e9, 0.8e9],
    },
    "USDC": CurrencyDefaults | {
        "address": "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
        "name": "USD Coin",
        "decimals": 6,
        "baseOracle": ChainlinkOracles["USDC/USD"],
        "quoteOracle": ChainlinkOracles["ETH/USD"],
        "invertBase": False,
        "invertQuote": False,

        "buffer": 109,
        "haircut": 92,
        "liquidationDiscount": 104,
        "maxUnderlyingSupply": 10_000e8,

        # Prime Cash Curve
        "primeCashCurve": {
            "kinkUtilization1": 10,
            "kinkUtilization2": 80,
            "kinkRate1": 5,
            "kinkRate2": 16,
            "maxRate25BPS": 192,
            "feeRatePercent": 20,
            "minFeeRate5BPS": 10,
            "maxFeeRate25BPS": 80
        },

        # fCash Curve
        "fCashCurves" : [{
            "kinkUtilization1": 15,
            "kinkUtilization2": 80,
            "kinkRate1": 17,
            "kinkRate2": 51,
            "maxRate25BPS": 120,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }, {
            "kinkUtilization1": 15,
            "kinkUtilization2": 80,
            "kinkRate1": 20,
            "kinkRate2": 61,
            "maxRate25BPS": 100,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }],

        "proportion": [0.5e9, 0.5e9],
        "depositShare": [0.55e8, 0.45e8],
        "leverageThreshold": [0.8e9, 0.8e9],
    },
    "WBTC": CurrencyDefaults | {
        "address": "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f",
        "name": "Wrapped BTC",
        "decimals": 8,
        "baseOracle": ChainlinkOracles["WBTC/USD"],
        "quoteOracle": ChainlinkOracles["ETH/USD"],
        "invertBase": False,
        "invertQuote": False,
        "minOracleRate": 16,
        "maxOracleRate": 20,

        "buffer": 124,
        "haircut": 81,
        "liquidationDiscount": 107,
        "maxUnderlyingSupply": 0.50e8,

        # Prime Cash Curve
        "primeCashCurve": {
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 1,
            "kinkRate2": 6,
            "maxRate25BPS": 255,
            "feeRatePercent": 20,
            "minFeeRate5BPS": 10,
            "maxFeeRate25BPS": 160
        },

        # fCash Curve
        "fCashCurves" : [{
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 4,
            "kinkRate2": 34,
            "maxRate25BPS": 120,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }, {
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 5,
            "kinkRate2": 41,
            "maxRate25BPS": 100,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }],

        "proportion": [0.5e9, 0.5e9],
        "depositShare": [0.50e8, 0.50e8],
        "leverageThreshold": [0.7e9, 0.7e9],
    },
    "wstETH": CurrencyDefaults | {
        "address": "0x5979D7b546E38E414F7E9822514be443A4800529",
        "name": "Wrapped Liquid Staked Ether",
        "decimals": 18,

        "baseOracle": ChainlinkOracles["wstETH/stETH"],
        "quoteOracle": ChainlinkOracles["stETH/ETH"],
        "invertBase": False,
        "invertQuote": True,
        "minOracleRate": 8,
        "maxOracleRate": 12,

        "buffer": 129,
        "haircut": 78,
        "liquidationDiscount": 106,
        "maxUnderlyingSupply": 10e8,

        # Prime Cash Curve
        "primeCashCurve": {
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 1,
            "kinkRate2": 3,
            "maxRate25BPS": 255,
            "feeRatePercent": 20,
            "minFeeRate5BPS": 10,
            "maxFeeRate25BPS": 160
        },

        # fCash Curve
        "fCashCurves" : [{
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 2,
            "kinkRate2": 17,
            "maxRate25BPS": 120,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }, {
            "kinkUtilization1": 15,
            "kinkUtilization2": 70,
            "kinkRate1": 2,
            "kinkRate2": 21,
            "maxRate25BPS": 100,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }],

        "proportion": [0.5e9, 0.5e9],
        "depositShare": [0.50e8, 0.50e8],
        "leverageThreshold": [0.7e9, 0.7e9],
    },
    "FRAX": CurrencyDefaults | {
        "address": "0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F",
        "name": "Frax",
        "decimals": 18,
        "baseOracle": ChainlinkOracles["FRAX/USD"],
        "quoteOracle": ChainlinkOracles["ETH/USD"],
        "invertBase": False,
        "invertQuote": False,

        "buffer": 109,
        "haircut": 0,
        "liquidationDiscount": 104,
        "maxUnderlyingSupply": 10_000e8,

        # Prime Cash Curve
        "primeCashCurve": {
            "kinkUtilization1": 10,
            "kinkUtilization2": 80,
            "kinkRate1": 5,
            "kinkRate2": 16,
            "maxRate25BPS": 192,
            "feeRatePercent": 20,
            "minFeeRate5BPS": 10,
            "maxFeeRate25BPS": 80
        },

        # fCash Curve
        "fCashCurves" : [{
            "kinkUtilization1": 15,
            "kinkUtilization2": 80,
            "kinkRate1": 17,
            "kinkRate2": 51,
            "maxRate25BPS": 120,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }, {
            "kinkUtilization1": 15,
            "kinkUtilization2": 80,
            "kinkRate1": 20,
            "kinkRate2": 61,
            "maxRate25BPS": 100,
            "feeRatePercent": 8,
            "minFeeRate5BPS": 3,
            "maxFeeRate25BPS": 8
        }],

        "proportion": [0.5e9, 0.5e9],
        "depositShare": [0.55e8, 0.45e8],
        "leverageThreshold": [0.8e9, 0.8e9],
    }
}

ListedOrder = ['ETH', 'DAI', 'USDC', 'WBTC', 'wstETH', 'FRAX']