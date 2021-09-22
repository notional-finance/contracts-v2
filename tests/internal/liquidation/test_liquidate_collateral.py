import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    get_expected,
    move_collateral_exchange_rate,
    setup_collateral_liquidation,
)

chain = Chain()

"""
Liquidate Collateral Test Matrix

Invariants:
    - FC increases
    - No balances go negative

1. Only Cash
    => calculateLiquidationAmount test
    => balance >= amount
    => balance < amount

2. Only Liquidity Token
    => Markets only update during non calculation
    => cashClaim >= amount
    => cashClaim < amount

3. Only nToken
    => nTokenValue >= amount
    => nTokenValue < amount
    => maxNTokenAmount >= amount, nTokenValue >= amount
    => maxNTokenAmount >= amount, nTokenValue < amount
    => maxNTokenAmount < amount, nTokenValue >= amount
    => maxNTokenAmount < amount, nTokenValue < amount

4. Cash + Liquidity Token
    => balance >= amount, cashClaim ?
    => balance < amount, cashClaim > amount
    => balance < amount, cashClaim < amount

5. Cash + nToken
    => balance >= amount, nTokenValue ?
    => balance < amount, nTokenValue > amount
    => balance < amount, nTokenValue < amount

6. Cash + Liquidity Token + nToken
    => balance >= amount, cashClaim ?, nTokenValue ?
    => balance < amount, cashClaim > amount, nTokenValue ?
    => balance < amount, cashClaim < amount, nTokenValue > amount
    => balance < amount, cashClaim < amount, nTokenValue < amount

7. Liquidity Token + nToken
    => cashClaim >= amount, nTokenValue ?
    => cashClaim < amount, nTokenValue > amount
    => cashClaim < amount, nTokenValue < amount

# For each liquidation:
1. calculate the local benefit
2. validate the liquidator amounts
3. validate the fc afterwards
"""


@pytest.mark.liquidation
class TestLiquidateCollateral:
    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self,
        MockCollateralLiquidation,
        SettleAssetsExternal,
        FreeCollateralExternal,
        FreeCollateralAtTime,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        FreeCollateralAtTime.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockCollateralLiquidation)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @pytest.mark.only
    @given(
        local=strategy("uint", min_value=1, max_value=4),
        localDebt=strategy("int", min_value=-100_000e8, max_value=-1e8),
        ratio=strategy("uint", min_value=5, max_value=150),
        numTokens=strategy("uint", min_value=0, max_value=3),
        cashShare=strategy("uint", min_value=0, max_value=100),
    )
    def test_liquidate_cash_and_liquidity_tokens(
        self, liquidation, accounts, local, localDebt, ratio, numTokens, cashShare
    ):
        blockTime = chain.time()

        # Set the local debt amount
        localDebtAsset = liquidation.calculate_from_underlying(local, localDebt)
        liquidation.mock.setBalance(accounts[0], local, localDebtAsset, 0)

        (collateral, collateralUnderlying) = setup_collateral_liquidation(
            liquidation, local, localDebt
        )
        marketsBefore = liquidation.mock.getActiveMarkets(collateral)

        # Set up the cash and liquidity token balances
        if numTokens == 0:
            cashShare = 100
        collateralAssetRequired = liquidation.calculate_from_underlying(
            collateral, collateralUnderlying
        )

        # Set up cash share
        collateralCashAsset = Wei(collateralAssetRequired * cashShare / 100)
        liquidation.mock.setBalance(accounts[0], collateral, collateralCashAsset, 0)

        # Set up liquidity token share
        tokenCashShare = collateralAssetRequired - collateralCashAsset
        (
            assets,
            totalCashClaim,  # This is recalculated from the tokens
            totalHaircutCashClaim,
            totalfCashResidual,
            totalHaircutfCashResidual,
            benefitsPerAsset,
        ) = liquidation.get_liquidity_tokens(collateral, tokenCashShare, numTokens, blockTime)
        liquidation.mock.setPortfolio(accounts[0], assets)

        # This is the haircut due to the liquidity tokens from collateralAssetRequired,
        # need to adjust our FC expectation accordingly
        cashDiff = tokenCashShare - (totalHaircutCashClaim + totalHaircutfCashResidual)
        # This is the ETH denominated value of the cash diff
        fcDiff = liquidation.calculate_to_eth(
            collateral, liquidation.calculate_to_underlying(collateral, cashDiff)
        )

        # There should be a FC ~ 0 at this point accounting for the fcDiff due to LTs
        (fc, _) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)
        assert pytest.approx(fc, rel=1e-6, abs=100) == -fcDiff

        # Moves the exchange rate based on the ratio
        (newExchangeRate, discountedExchangeRate) = move_collateral_exchange_rate(
            liquidation, local, collateral, ratio
        )

        # FC is be negative at this point
        (fc, netLocal) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)
        collateralAvailable = netLocal[1 if collateral > local else 0]

        (
            expectedCollateralTrade,
            expectedNetETHBenefit,
            collateralToSell,
            collateralDenominatedFC,
        ) = get_expected(
            liquidation,
            local,
            collateral,
            newExchangeRate,
            discountedExchangeRate,
            liquidation.calculate_to_underlying(collateral, collateralAvailable),
            fc,
        )

        # Convert to asset cash
        expectedCollateralTradeAsset = liquidation.calculate_from_underlying(
            collateral, expectedCollateralTrade
        )

        txn = liquidation.mock.calculateCollateralCurrencyTokens(
            accounts[0], local, collateral, 0, 0, {"from": accounts[1]}
        )

        (
            localAssetCashFromLiquidator,
            collateralAssetCashToLiquidator,
            nTokensPurchased,
            netCashWithdrawn,
            balanceState,
            portfolio,
        ) = txn.events["CollateralLiquidationTokens"][0].values()

        assert (
            pytest.approx(collateralAssetCashToLiquidator, rel=1e-6, abs=100)
            == expectedCollateralTradeAsset
        )
        assert nTokensPurchased == 0

        # IN UNDERLYING #
        # Check that the price is correct (underlying)
        collateralCashFinal = liquidation.calculate_to_underlying(
            collateral, collateralAssetCashToLiquidator
        )
        localCashFinal = liquidation.calculate_to_underlying(local, localAssetCashFromLiquidator)
        assert (
            pytest.approx((localCashFinal * discountedExchangeRate) / 1e18, rel=1e-6)
            == collateralCashFinal
        )
        # END UNDERLYING #
        # ASSET VALUES
        liquidation.mock.setPortfolioState(accounts[0], portfolio)
        liquidation.mock.setBalance(
            accounts[0], local, localDebtAsset + localAssetCashFromLiquidator, 0
        )

        # Cannot liquidate to negative collateral
        assert (collateralCashAsset - collateralAssetCashToLiquidator + netCashWithdrawn) >= 0
        liquidation.mock.setBalance(
            accounts[0],
            collateral,
            collateralCashAsset - collateralAssetCashToLiquidator + netCashWithdrawn,
            0,
        )
        # ASSET VALUES

        (_, _, portfolioAfter) = liquidation.mock.getAccount(accounts[0])
        marketsAfter = liquidation.mock.getActiveMarkets(collateral)

        # This checks that the tokens and fCash withdrawn align with markets exactly
        totalCashChange = liquidation.validate_market_changes(
            assets, portfolioAfter, marketsBefore, marketsAfter
        )
        assert pytest.approx(totalCashChange, abs=1) == netCashWithdrawn

        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)
        # TODO: this does not work...
        # assert pytest.approx(fc - expectedNetETHBenefit, rel=1e-6, abs=100) == fcAfter

    def test_liquidate_cash_liquidity_tokens_ntokens(
        self, liquidation, accounts, local, localDebt, ratio
    ):
        pass

    def test_liquidate_limits(self, liquidation, accounts, local, localDebt, ratio):
        pass

    def test_liquidate_tokens_no_change(self, liquidation, accounts):
        pass
