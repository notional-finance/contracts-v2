# Jan 1 2021
START_TIME = 1609459200
SECONDS_IN_DAY = 86400
SECONDS_IN_YEAR = SECONDS_IN_DAY * 360
RATE_PRECISION = 1e9
TOKEN_PRECISION = 1e8
BASIS_POINT = RATE_PRECISION / 10000
NORMALIZED_RATE_TIME = 31104000
START_TIME_TREF = START_TIME - START_TIME % (90 * SECONDS_IN_DAY)
SETTLEMENT_DATE = START_TIME_TREF + (90 * SECONDS_IN_DAY)

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
    (100, 99, 98, 97, 96, 95, 94, 93, 92),
    # 8: rate scalar (increments of 10)
    (10, 9, 8, 7, 6, 5, 4, 3, 2),
)

IDENTITY_ASSET_RATE = ("0x0000000000000000000000000000000000000000", 1e18, 1e8)


def get_cash_group_hex(parameters):
    # tmp = (parameters[-1].to_bytes(2, "big") + bytes(list(reversed(parameters[0:-1])))).hex()
    tmp = "0"
    return "0x" + tmp.rjust(64, "0")


BASE_CASH_GROUP = [
    1,  # 0: cash group id
    9,  # 1: max market index
    IDENTITY_ASSET_RATE,
    get_cash_group_hex(CASH_GROUP_PARAMETERS),
]
