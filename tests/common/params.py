from brownie.test import strategy

# Jan 1 2021
START_TIME = 1609459200
SECONDS_IN_DAY = 86400
SECONDS_IN_YEAR = SECONDS_IN_DAY * 360
RATE_PRECISION = 1e9
BASIS_POINT = RATE_PRECISION / 10000
NORMALIZED_RATE_TIME = 31104000

MARKETS = [
    START_TIME + 90 * SECONDS_IN_DAY,
    START_TIME + 180 * SECONDS_IN_DAY,
    START_TIME + SECONDS_IN_YEAR,
    START_TIME + 2 * SECONDS_IN_YEAR,
    START_TIME + 5 * SECONDS_IN_YEAR,
    START_TIME + 7 * SECONDS_IN_YEAR,
    START_TIME + 10 * SECONDS_IN_YEAR,
    START_TIME + 15 * SECONDS_IN_YEAR,
    START_TIME + 20 * SECONDS_IN_YEAR,
]

IDENTITY_ASSET_RATE = ("0x0000000000000000000000000000000000000000", 1e18, 18)

CASH_GROUP_PARAMETERS = (
    9,  # 0: Max Market Index
    10,  # 1: time window, 10 min
    30,  # 2: liquidity fee, 30 BPS
    97,  # 3: liquidity token haircut (97%)
    30,  # 4: debt buffer 30 bps
    30,  # 5: fcash haircut 30 bps
    100,  # 6: rate scalar
)


def get_cash_group_hex(parameters):
    tmp = (parameters[-1].to_bytes(2, "big") + bytes(list(reversed(parameters[0:-1])))).hex()
    return "0x" + tmp.rjust(64, "0")


BASE_CASH_GROUP = [
    1,  # 0: cash group id
    9,  # 1: max market index
    IDENTITY_ASSET_RATE,
    get_cash_group_hex(CASH_GROUP_PARAMETERS),
]

timeToMaturityStrategy = strategy("uint", min_value=90, max_value=7200)
impliedRateStrategy = strategy(
    "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
)

ADD_LIQUIDITY = 0
REMOVE_LIQUIDITY = 1
TAKE_FCASH = 2
TAKE_CURRENT_CASH = 3
MINT_CASH_PAIR = 4
