# Liquidation

Liquidation ensures that Notional has enough capital to pay lenders and liquidity providers when they want to withdraw from the system. Because Notional allows for many types of collateral (asset cash, fCash, liquidity tokens, nTokens) there are many routes to liquidating an account in Notional.

## Terminology

- Local currency: this is the currency that the liquidator must provide to the account. If an account has borrowed DAI and collateralized with ETH, the DAI is the local currency.
- Collateral currency: the currency that collateral is held in. This is unset for local currency only liquidations.
- Local available: `netPortfolioValue + netCashBalance + netNTokenValue` from the free collateral calculation before the conversion to ETH.
- Collateral available: Same as local available but in the collateral currency.
- Local benefit required: the amount of local currency required to bring an account back to positive free collateral
- Collateral benefit: the amount of collateral currency required to bring an account back to positive free collateral

## Invariants

A liquidated account cannot assume debt as a result of liquidation. In practical terms this means that:

- If local available is positive, it cannot go below zero.
- If collateral available is positive, it cannot go below zero.
- If local available is negative, it cannot become more negative.
- Free collateral after the liquidation must be greater than free collateral before the liquidation.

## Local Currency

Local currency liquidation occurs when **local available** is negative and the account holds liquidity tokens or local currency nTokens. Because both those assets have haircuts applied, the account's collateral position can increase by the haircut amount minus any incentive paid to the liquidator.

To be eligible for this liquidation an account may have:

- Provided liquidity directly to a market and have a resulting net negative fCash position. This can occur by either borrowing against liquidity token collateral or providing liquidity while a market has high interest rates.
- Holds nTokens in local currency and is a net borrower in local currency
- A debt in a different currency and holds local currency liquidity tokens or nTokens. In this case the potential for free collateral change is quite small but still non zero.

If interest rates continue to increase, the value of nTokens and liquidity tokens will decrease. Note that higher interest rates also reduce the account's collateral requirements for negative fCash so this has some countervailing effect.

### Withdraw Liquidity Tokens

Withdrawing liquidity tokens from the market will convert the shifting liquidity token value into a fixed cash and fCash value. This will reduce the volatility of the account's value. It will also add collateral back to the account by removing the liquidity token haircut on the cash and fCash claims.

This action does not require the liquidator to provide any local currency. The liquidator is instead paid an incentive for taking this action from the cash claim withdrawn.

### Local Currency nTokens

A liquidator may purchase nTokens for local currency at a discount. nTokens have a risk adjusted value of `nTokenPresentValue * haircut` and a liquidator may purchase nTokens at a liquidation value of `nTokenPresentValue * liquidationHaircut`. When setting the parameters, `liquidationHaircut > haircut` to ensure that some positive collateral value will flow back to the liquidated account.

The additional collateral back to the account will be: `nTokenPresentValue * (liquidationHaircut - haircut)`

## Collateral Currency

Collateral currency liquidation is likely the most common liquidation. In this situation, debts are in local currency and collateral is in a different currency. The value of the collateral has fallen relative to the local currency and it may be purchased at a discount for local currency. For this liquidation to occur the conditions must be met:

- Account has net negative local available
- Account has net positive collateral available

Collateral to purchase can take three forms: asset cash balance, collateral currency liquidity tokens, nToken balances.

### Collateral Benefit

The additional free collateral to the liquidated account is a balance between the reduction in local currency debt and the decrease in collateral available. Mathematically speaking, this benefit is:

```
collateralDenominatedBenefit = reductionInDebt - decreaseInCollateral
reductionInDebt = localPurchased * localCurrencyBuffer * exchangeRate
decreaseInCollateral = collateralSold * collateralHaircut

collateralDenominatedBenefit = localPurchased * localCurrencyBuffer * exchangeRate - collateralSold * collateralHaircut
```

The contribution of collateral to the overall free collateral of an account is:

`freeCollateralContribution = collateral * collateralHaircut * ethExchangeRate`

And the rate at which local currency is purchased must incorporate a discount given to the liquidator as an incentive:

`localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)`

Setting `freeCollateralContribution = collateralDenominatedBenefit` we can solve for the ideal `collateralSold` to recapitalize the account:

`collateralSold = collateralDenominatedBenefit / ((localCurrencyBuffer / liquidationDiscount) - collateralHaircut)`

### Withdrawing Liquidity

Withdrawing liquidity tokens makes any resulting collateral cash claims available to the liquidator. No additional incentive is paid to the liquidator.

### Collateral Currency nTokens

Similar to local currency nTokens, the liquidator purchases collateral nTokens at a `liquidationHaircut`. The amount of nTokens to liquidate is calculated given:

The value of nTokens is defined as: `nTokenHaircutValue = nTokenPV * haircut`

The liquidation price of nTokens is defined as: `nTokenLiquidationValue = nTokenPV * liquidationHaircut`

The number of tokens to liquidate given is: `tokensToLiquidate = collateralToRaise * tokenBalance / (nTokenPV * liquidationHaircut)`

### Limits to Collateral Purchased

If a liquidator purchases too much collateral it may no longer be the case that an account's free collateral position will increase. This is due to potential differences in the haircuts and buffers given to the local currency and collateral currency. To ensure this, the collateral purchased is limited to the point where local available is zero.

## fCash Liquidation

Positive fCash is collateral for accounts in Notional and therefore can be liquidated. In these liquidations, the liquidator takes possession of fCash assets in return for providing local currency to an account.

## fCash Local Currency

Liquidation fCash in local currency can be done in either two conditions:

- Total free collateral is negative but local available is positive. This can occur when borrowing in a different currency collateralized by local currency fCash.
- The account has negative local available. This can occur if the account has borrowed and lent fCash at different maturities in the local currency.

In either of these cases, the benefit to the account is based on the difference between the `liquidationDiscountFactor` and the `riskAdjustedDiscountFactor`. For example, if the risk adjusted fCash haircut is 300 basis points (3%) then the liquidation discount haircut may be 150 basis points (1.5%). The liquidator will purchase fCash at 150 basis points below market value and the account will receive local currency cash. The benefit to their free collateral is equal to `benefit = fCashSold * (liquidationDiscountFactor - riskAdjustedDiscountFactor)`

## fCash Cross Currency

Cross currency fCash liquidation is similar to local currency fCash liquidation except that the liquidator provides local currency but purchases fCash denominated in a collateral currency. This situation can arise when an account borrows in local currency but is lending the collateral currency.

Similar to collateral currency liquidation, the account must have negative local available and positive collateral available. The calculations are a combination of determining the collateral to sell as well as the benefit gained by converting fCash to cash (`totalBenefit = fCashBenefit + collateralBenefit`).

```
fCashBenefit = fCashSold * (liquidationDiscountFactor - riskAdjustedDiscountFactor)
collateralBenefit = collateralSold * ((localBuffer / liquidationDiscount) - collateralHaircut)
```

During this liquidation it must be ensured that the account's free collateral position does not decrease. This is ensured by checking that:

- Local available does not go above zero.
- Collateral available does not go below zero.

The change to local available is:

`deltaLocalAvailable = (fCashSold * liquidationDiscountFactor) / (exchangeRate * liquidationDiscount)`

The change to collateral available is:

`deltaCollateralAvailable = -(fCashSold * riskAdjustedPV)`

## Liquidator Parameters

During times of price volatility and high gas prices, it is safer and more gas efficient to liquidate an account to a free collateral position that is much more than zero. The liquidated account will be more resilient to continued price volatility. This will also increase liquidation profitability for liquidators. To allow for this, Notional has a `DEFAULT_LIQUIDATION_PORTION` that allows liquidators to purchase additional collateral above the minimum required to recollateralize an account.

Liquidators may want also want to limit the amount of collateral, nTokens or fCash they purchase. Where relevant, the liquidator can specify the maximum amount of assets they want to purchase.
