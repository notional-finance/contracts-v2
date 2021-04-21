# Valuation

Each Notional on chain market produces an oracle rate of of the annualized interest rate traded at that particular maturity. Notional uses these oracle rates to value fCash assets in a portfolio using continuous compounding. For example, a positive fCash asset with a maturity of Jan 1 2022 will be referenced by an on chain market that is trading fCash of the same maturity. If the market produces an oracle rate of 6% annualized, the fCash asset will be valued at its present value of `fCash notional * e^(-(rate +/- haircut) * time)`.

## Oracle Rate

All AMM (automated market makers) are vulnerable to flash loan manipulation, where an attacker borrows an enormous sum of tokens for a single transaction to move a market temporarily and find arbitrage opportunities. Notional side steps this issue by recording two market rates, the `lastImpliedRate` and the `oracleRate`. The `lastImpliedRate` is the last rate the market traded at and used to calculate the liquidity curve at the next trade. `oracleRate` is calculated whenever a market is loaded from storage from trading. The formula is:

```
    lastImpliedRatePreTrade * (currentTs - previousTs) / timeWindow +
        oracleRatePrevious * (1 - (currentTs - previousTs) / timeWindow)
```

This oracle rate

## fCash Haircuts and Buffers

## Idiosyncratic fCash

## Free Collateral
