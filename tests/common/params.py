from brownie.test import strategy

# Jan 1 2021
START_TIME = 1609459200
SECONDS_IN_DAY = 86400
SECONDS_IN_YEAR = SECONDS_IN_DAY * 360
RATE_PRECISION = 1e9
BASIS_POINT = RATE_PRECISION / 10000
NORMALIZED_RATE_TIME = 31104000

IDENTITY_ASSET_RATE = (1e18, 1e18, 1e18, 1e18, 100, 100)

BASE_CASH_GROUP = [
    1,  # 0: cash group id
    600,  # 1: time window, 10 min
    30 * BASIS_POINT,  # 2: liquidity fee, 30 BPS
    100,  # 3: rate scalar
    8,  # 4: max market index
    97,  # 5: liquidity token haircut (97%)
    30 * BASIS_POINT,  # 6: debt buffer 30 bps
    30 * BASIS_POINT,  # 7: fcash haircut 30 bps
    IDENTITY_ASSET_RATE,
]

timeToMaturityStrategy = strategy("uint", min_value=90, max_value=7200)
impliedRateStrategy = strategy(
    "uint", min_value=0.01 * RATE_PRECISION, max_value=0.40 * RATE_PRECISION
)
