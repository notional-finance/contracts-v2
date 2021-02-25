TokenConfig = {
    "DAI": {"name": "Dai Stablecoin", "decimals": 18, "fee": 0, "rate": 0.01e18},
    "USDC": {"name": "USD Coin", "decimals": 6, "fee": 0, "rate": 0.01e18},
    "USDT": {"name": "Tether USD", "decimals": 6, "fee": 0.001e18, "rate": 0.01e18},
    "WBTC": {"name": "Wrapped Bitcoin", "decimals": 8, "fee": 0, "rate": 100e18},
}

CurrencyDefaults = {
    "buffer": 140,
    "haircut": 100,
    "liquidationDiscount": 105,
    "maxMarketIndex": 2,
    "rateOracleTimeWindow": 20,
    "liquidityFee": 30,
    "tokenHaircut": 95,
    "debtBuffer": 30,
    "fCashHaircut": 30,
    "rateScalar": 100,
}
