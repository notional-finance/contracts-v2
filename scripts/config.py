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

CompoundConfig = {
    # cETH uses whitepaper interest rate model
    # cETH: https://etherscan.io/address/0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5
    # Interest Rate Model:
    # https://etherscan.io/address/0x0c3f8df27e1a00b47653fde878d68d35f00714c0
    "ETH": {
        "initialExchangeRate": 200000000000000000000000000,
        "interestRateModel": {
            "name": "whitepaper",
            "baseRate": 20000000000000000,
            "multiplier": 100000000000000000,
        },
    },
    # cWBTC uses whitepaper interest rate model
    # cWBTC https://etherscan.io/address/0xc11b1268c1a384e55c48c2391d8d480264a3a7f4
    # Interest Rate Model:
    # https://etherscan.io/address/0xbae04cbf96391086dc643e842b517734e214d698#code
    "WBTC": {
        "initialExchangeRate": 20000000000000000,
        "interestRateModel": {
            "name": "whitepaper",
            "baseRate": 20000000000000000,
            "multiplier": 300000000000000000,
        },
    },
    # cDai: https://etherscan.io/address/0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643
    # Jump interest rate model:
    # https://etherscan.io/address/0xfb564da37b41b2f6b6edcc3e56fbf523bd9f2012
    "DAI": {
        "initialExchangeRate": 200000000000000000000000000,
        "interestRateModel": {
            "name": "jump",
            "baseRate": 0,
            "multiplier": 40000000000000000,
            "jumpMultiplierPerYear": 1090000000000000000,
            "kink": 800000000000000000,
        },
    },
    # cUSDC: https://etherscan.io/address/0x39aa39c021dfbae8fac545936693ac917d5e7563
    # Jump interest rate model:
    # https://etherscan.io/address/0xd8ec56013ea119e7181d231e5048f90fbbe753c0
    "USDC": {
        "initialExchangeRate": 200000000000000,
        "interestRateModel": {
            "name": "jump",
            "baseRate": 0,
            "multiplier": 40000000000000000,
            "jumpMultiplierPerYear": 1090000000000000000,
            "kink": 800000000000000000,
        },
    },
    # cTether: https://etherscan.io/address/0xf650c3d88d12db855b8bf7d11be6c55a4e07dcc9
    # Jump Rate mode: https://etherscan.io/address/0xfb564da37b41b2f6b6edcc3e56fbf523bd9f2012
    "USDT": {
        "initialExchangeRate": 200000000000000,
        "interestRateModel": {
            "name": "jump",
            "baseRate": 0,
            "multiplier": 40000000000000000,
            "jumpMultiplierPerYear": 1090000000000000000,
            "kink": 800000000000000000,
        },
    },
}
