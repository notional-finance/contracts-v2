from brownie.convert import to_int
from brownie.convert.datatypes import HexString

# Jan 1 2021
START_TIME = 1609459200
SECONDS_IN_DAY = 86400
SECONDS_IN_YEAR = SECONDS_IN_DAY * 360
SECONDS_IN_QUARTER = SECONDS_IN_DAY * 90
RATE_PRECISION = 1e9
TOKEN_PRECISION = 1e8
BASIS_POINT = RATE_PRECISION / 10000
NORMALIZED_RATE_TIME = 31104000
START_TIME_TREF = START_TIME - START_TIME % (90 * SECONDS_IN_DAY)
SETTLEMENT_DATE = START_TIME_TREF + (90 * SECONDS_IN_DAY)
FCASH_ASSET_TYPE = 1

PORTFOLIO_FLAG = HexString("0x8000", "bytes2")
BALANCE_FLAG = HexString("0x4000", "bytes2")
PORTFOLIO_FLAG_INT = to_int(HexString("0x8000", "bytes2"), "int")
BALANCE_FLAG_INT = to_int(HexString("0x4000", "bytes2"), "int")

MARKETS = [
    START_TIME_TREF + 90 * SECONDS_IN_DAY,
    START_TIME_TREF + 180 * SECONDS_IN_DAY,
    START_TIME_TREF + SECONDS_IN_YEAR,
    START_TIME_TREF + 2 * SECONDS_IN_YEAR,
    START_TIME_TREF + 5 * SECONDS_IN_YEAR,
    START_TIME_TREF + 7 * SECONDS_IN_YEAR,
    START_TIME_TREF + 10 * SECONDS_IN_YEAR,
    START_TIME_TREF + 15 * SECONDS_IN_YEAR,
    START_TIME_TREF + 20 * SECONDS_IN_YEAR,
]

CASH_GROUP_PARAMETERS = (
    9,  # 0: Max Market Index
    10,  # 1: time window, 10 min
    30,  # 2: liquidity fee, 30 BPS
    30,  # 3: debt buffer 150 bps
    30,  # 4: fcash haircut 150 bps
    40,  # 5: settlement penalty 400 bps
    40,  # 6: liquidityRepoDiscount 400 bps
    # 7: token haircuts (percentages)
    (99, 98, 97, 96, 95, 94, 93, 92, 91),
    # 8: rate scalar (increments of 10)
    (10, 9, 8, 7, 6, 5, 4, 3, 2),
)

CURVE_SHAPES = {
    "flat": {
        "rates": [
            r * RATE_PRECISION for r in [0.03, 0.035, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10]
        ],
        "proportion": 0.33,
    },
    "normal": {
        "rates": [
            r * RATE_PRECISION for r in [0.06, 0.065, 0.07, 0.08, 0.09, 0.10, 0.11, 0.12, 0.13]
        ],
        "proportion": 0.5,
    },
    "high": {
        "rates": [
            r * RATE_PRECISION for r in [0.08, 0.09, 0.10, 0.11, 0.12, 0.13, 0.14, 0.15, 0.16]
        ],
        "proportion": 0.8,
    },
}

DEPOSIT_ACTION_TYPE = {
    "None": 0,
    "DepositAsset": 1,
    "DepositUnderlying": 2,
    "DepositAssetAndMintPerpetual": 3,
    "DepositUnderlyingAndMintPerpetual": 4,
    "RedeemPerpetual": 5,
}
