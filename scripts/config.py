GovernanceConfig = {
    "initialBalances": {
        "DAO": 55_000_000e8,
        "MULTISIG": 45_000_000e8,  # TODO: update this to account for airdrop
    },
    "governorConfig": {
        "quorumVotes": 4_000_000e8,
        "proposalThreshold": 1_000_000e8,
        "votingDelayBlocks": 1,
        "votingPeriodBlocks": 10,  # TODO: override ths for real
        "minDelay": 86400,
    },
}

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
    # Cash group settings
    "maxMarketIndex": 2,
    "rateOracleTimeWindow": 20,
    "totalFee": 30,
    "reserveFeeShare": 50,
    "debtBuffer": 30,
    "fCashHaircut": 30,
    "settlementPenalty": 40,
    "liquidationfCashDiscount": 40,
    "tokenHaircut": (99, 98, 97, 96, 95, 94, 93, 92, 91),
    "rateScalar": (30, 25, 20, 17, 16, 15, 14, 13, 12),
    "incentiveEmissionRate": 0.005e8,
}

PerpetualTokenDefaults = {
    "Deposit": [[0.4e8, 0.6e8], [0.8e9, 0.8e9]],  # Deposit shares  # Leverage thresholds
    "Initialization": [[1.01e9, 1.021e9], [0.5e9, 0.5e9]],  # Rate anchors  # Target proportion
    "Collateral": [
        30,  # residual purchase incentive bps
        90,  # pv haircut
        96,  # time buffer hours
        50,  # cash withholding
        95,  # liquidation haircut percentage
    ],
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
