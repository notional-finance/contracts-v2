import random

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.helpers import get_fcash_token, get_liquidity_token
from tests.internal.liquidation.liquidation_helpers import ValuationMock

chain = Chain()
REPO_INCENTIVE = 10

"""
Liquidate Local Currency Test Matrix:

1. Only nToken
    => calculateLiquidationAmount test
    => nTokensToLiquidateHaircutValue > netAssetCashFromLiquidator
2. Only Liquidity Token
    => Markets Update in actual
    => Markets don't update in calculate
    => Portfolio updates in actual
    => incentive is paid to liquidator
    => cash removed and fCash removed nets off
3. Both
    => assetBenefitRequired falls through from liquidity token to nToken
    => netAssetCashFromLiquidator is the net of the incentive paid and the nTokenLiquidateValue
"""


@pytest.mark.liquidation
class TestLiquidateLocalNTokens:
    @pytest.fixture(scope="module", autouse=True)
    def liquidation(
        self, MockLocalLiquidation, SettleAssetsExternal, FreeCollateralExternal, accounts
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockLocalLiquidation)

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_negative_local_available(
        self, liquidation, accounts, currency, nTokenBalance, ratio
    ):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "liquidator")
        benefit = liquidator - haircut

        # if cashBalance < -haircut then under fc
        # if cashBalance < -liquidator then insolvent
        # ratio of 100 == liquidator, ratio > 100 is insolvent
        cashBalance = -Wei(haircut + (benefit * ratio * 1e8) / 1e10)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, nTokenBalance)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, 0, {"from": accounts[1]}
        )
        # Check that the price returned is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, "liquidator")
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        # Simulate the transfer above and check the FC afterwards
        liquidation.mock.setBalance(
            accounts[0],
            currency,
            cashBalance + localAssetCashFromLiquidator,
            nTokenBalance - nTokensPurchased,
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0])

        if ratio <= 40:
            # In the case that the ratio is less than 40%, we liquidate up to 40%
            assert pytest.approx(Wei(netLocal[0] + benefit * 0.40), abs=5) == netLocalAfter[0]
            assert fcAfter > 0
        elif ratio > 100:
            # In this scenario we liquidate all the nTokens and are still undercollateralized
            assert nTokenBalance == nTokensPurchased
            assert pytest.approx(Wei(netLocal[0] + benefit), abs=5) == netLocalAfter[0]
            assert fcAfter < 0
        else:
            # In each of these scenarios sufficient nTokens exist to liquidate to zero fc,
            # some dust will exist when rounding this back to zero, we may undershoot due to
            # truncation in solidity math
            assert -1e5 <= netLocalAfter[0] and netLocalAfter[0] <= 0
            assert -100 <= fcAfter and fcAfter <= 0

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        nTokenLimit=strategy("uint", min_value=1, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_negative_local_available_user_limit(
        self, liquidation, accounts, currency, nTokenBalance, ratio, nTokenLimit
    ):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "liquidator")
        benefit = liquidator - haircut

        # if cashBalance < -haircut then under fc
        # if cashBalance < -liquidator then insolvent
        # ratio of 100 == liquidator, ratio > 100 is insolvent
        cashBalance = -Wei(haircut + (benefit * ratio * 1e8) / 1e10)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, nTokenBalance)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, nTokenLimit, {"from": accounts[1]}
        )

        assert nTokensPurchased <= nTokenLimit
        # Check that the price returned is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, "liquidator")

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_positive_local_available(
        self, liquidation, accounts, currency, nTokenBalance, ratio
    ):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "liquidator")
        benefit = liquidator - haircut
        # Choose a random currency for the debt to be in
        debtCurrency = random.choice([c for c in range(1, 5) if c != currency])

        # Convert from nToken asset value to debt balance value
        # if (signed terms) debt cash balance < -(benefit + nTokenHaircutValue) then insolvent
        # if -(benefit + nTokenHaircutValue) < debt cash balance < 0 then ok

        # Max benefit to the debt currency is going to be, we don't actually pay off any
        # debt in this liquidation type:
        # convertToETHWithHaircut(benefit) + convertToETHWithBuffer(debt)
        benefitInUnderlying = liquidation.calculate_to_underlying(
            currency, Wei((benefit * ratio * 1e8) / 1e10)
        )
        # Since this benefit is cross currency, apply the haircut here
        benefitInETH = liquidation.calculate_to_eth(currency, benefitInUnderlying)

        # However, we need to also ensure that this account is undercollateralized, so the debt cash
        # balance needs to be lower than the value of the haircut nToken value:
        # convertToETHWithHaircut(nTokenHaircut) = convertToETHWithBuffer(debt)
        haircutInETH = liquidation.calculate_to_eth(
            currency, liquidation.calculate_to_underlying(currency, Wei(haircut))
        )

        # This is the amount of debt post buffer we can offset with the benefit in ETH
        debtInUnderlyingBuffered = liquidation.calculate_from_eth(
            debtCurrency, benefitInETH + haircutInETH
        )
        # Undo the buffer when calculating the cash balance
        debtCashBalance = liquidation.calculate_from_underlying(
            debtCurrency,
            Wei(
                (debtInUnderlyingBuffered * 100)
                / liquidation.bufferHaircutDiscount[debtCurrency][0]
            ),
        )

        # Set the proper balances
        liquidation.mock.setBalance(accounts[0], currency, 0, nTokenBalance)
        liquidation.mock.setBalance(accounts[0], debtCurrency, -debtCashBalance, 0)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, 0, {"from": accounts[1]}
        )
        # Check that the price is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, "liquidator")
        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        # Simulate the transfer above and check the FC afterwards
        liquidation.mock.setBalance(
            accounts[0], currency, localAssetCashFromLiquidator, nTokenBalance - nTokensPurchased
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0])

        nTokenNetLocal = netLocal[0] if currency < debtCurrency else netLocal[1]
        nTokenNetLocalAfter = netLocalAfter[0] if currency < debtCurrency else netLocalAfter[1]

        if ratio <= 40:
            # In the case that the ratio is less than 40%, we liquidate up to 40%
            assert pytest.approx(Wei(nTokenNetLocal + benefit * 0.40), abs=5) == nTokenNetLocalAfter
            assert fcAfter > 0
        elif ratio > 100:
            # In this scenario we liquidate all the nTokens and are still undercollateralized
            assert nTokenBalance == nTokensPurchased
            assert pytest.approx(Wei(nTokenNetLocal + benefit), abs=5) == nTokenNetLocalAfter
            assert fcAfter < 0
        else:
            # In this case the benefit is proportional to the amount liquidated
            benefit = Wei((benefit * nTokensPurchased) / nTokenBalance)
            assert pytest.approx(Wei(nTokenNetLocal + benefit), abs=5) == nTokenNetLocalAfter
            assert -100 <= fcAfter and fcAfter <= 0

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        nTokenLimit=strategy("uint", min_value=1, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_positive_local_available_user_limit(
        self, liquidation, accounts, currency, nTokenBalance, nTokenLimit, ratio
    ):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, "liquidator")
        benefit = liquidator - haircut
        # Choose a random currency for the debt to be in
        debtCurrency = random.choice([c for c in range(1, 5) if c != currency])

        # Convert from nToken asset value to debt balance value
        # if (signed terms) debt cash balance < -(benefit + nTokenHaircutValue) then insolvent
        # if -(benefit + nTokenHaircutValue) < debt cash balance < 0 then ok

        # Max benefit to the debt currency is going to be, we don't actually pay off any debt
        # convertToETHWithHaircut(benefit) + convertToETHWithBuffer(debt)
        benefitInUnderlying = liquidation.calculate_to_underlying(
            currency, Wei((benefit * ratio * 1e8) / 1e10)
        )
        # Since this benefit is cross currency, apply the haircut here
        benefitInETH = liquidation.calculate_to_eth(currency, benefitInUnderlying)

        # However, we need to also ensure that this account is undercollateralized, so the debt cash
        # balance needs to be lower than the value of the haircut nToken value:
        # convertToETHWithHaircut(nTokenHaircut) = convertToETHWithBuffer(debt)
        haircutInETH = liquidation.calculate_to_eth(
            currency, liquidation.calculate_to_underlying(currency, Wei(haircut))
        )

        # This is the amount of debt post buffer we can offset with the benefit in ETH
        debtInUnderlyingBuffered = liquidation.calculate_from_eth(
            debtCurrency, benefitInETH + haircutInETH
        )
        # Undo the buffer when calculating the cash balance
        debtCashBalance = liquidation.calculate_from_underlying(
            debtCurrency,
            Wei(
                (debtInUnderlyingBuffered * 100)
                / liquidation.bufferHaircutDiscount[debtCurrency][0]
            ),
        )

        # Set the proper balances
        liquidation.mock.setBalance(accounts[0], currency, 0, nTokenBalance)
        liquidation.mock.setBalance(accounts[0], debtCurrency, -debtCashBalance, 0)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, nTokenLimit, {"from": accounts[1]}
        )

        assert nTokensPurchased <= nTokenLimit
        # Check that the price returned is correct
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, "liquidator")

    @given(
        debtBalance=strategy("uint", min_value=1e8, max_value=100_000_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
    )
    def test_ntoken_local_no_currency(self, liquidation, accounts, currency, debtBalance):
        liquidation.mock.setBalance(accounts[0], currency, -debtBalance, 0)
        localCurrency = random.choice([c for c in range(1, 5) if c != currency])

        # There is no value in this local currency, we revert
        with brownie.reverts():
            liquidation.mock.calculateLocalCurrencyLiquidation.call(
                accounts[0], localCurrency, 0, {"from": accounts[1]}
            )

    @given(
        debtBalance=strategy("uint", min_value=10_000e8, max_value=100_000_000e8),
        debtCurrency=strategy("uint", min_value=1, max_value=4),
    )
    def test_ntoken_local_no_ntokens(self, liquidation, accounts, debtCurrency, debtBalance):
        localCurrency = random.choice([c for c in range(1, 5) if c != debtCurrency])
        liquidation.mock.setBalance(accounts[0], localCurrency, 1e8, 0)
        liquidation.mock.setBalance(accounts[0], debtCurrency, -debtBalance, 0)

        # In this case there is a debt and local available, but there are no nTokens
        # to liquidate
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], localCurrency, 0, {"from": accounts[1]}
        )

        assert localAssetCashFromLiquidator == 0
        assert nTokensPurchased == 0

    @pytest.mark.only
    @given(
        marketIndex=strategy("uint", min_value=1, max_value=3),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=5, max_value=150),
        tokens=strategy("uint", min_value=1e8, max_value=100_000_000e8),
    )
    def test_liquidity_token_negative_available(
        self, liquidation, accounts, marketIndex, currency, ratio, tokens
    ):
        # TODO: allow for multiple liquidity tokens
        marketsBefore = liquidation.mock.getActiveMarkets(currency)
        haircuts = liquidation.mock.getLiquidityTokenHaircuts(currency)

        # Need to calculate the value of any fCash residual from the haircut
        totalfCashClaim = Wei(
            (tokens * marketsBefore[marketIndex - 1][2]) / marketsBefore[marketIndex - 1][4]
        )
        totalHaircutfCashClaim = Wei(totalfCashClaim * haircuts[marketIndex - 1] / 100)
        fCashResidualPV = liquidation.mock.getRiskAdjustedPresentfCashValue(
            get_fcash_token(
                marketIndex,
                currencyId=currency,
                notional=-(totalfCashClaim - totalHaircutfCashClaim),
            ),
            chain.time(),
        )
        fCashResidualAssetValue = liquidation.calculate_from_underlying(currency, fCashResidualPV)

        # The amount of benefit to the account is totalCashClaim - totalHaircutCashClaim - incentive
        totalCashClaim = Wei(
            (tokens * marketsBefore[marketIndex - 1][3]) / marketsBefore[marketIndex - 1][4]
        )
        totalHaircutCashClaim = totalCashClaim * haircuts[marketIndex - 1] / 100
        benefit = totalCashClaim - totalHaircutCashClaim

        liquidation.mock.setPortfolio(
            accounts[0],
            [
                get_liquidity_token(marketIndex, currencyId=currency, notional=tokens),
                get_fcash_token(marketIndex, currencyId=currency, notional=-totalfCashClaim),
            ],
        )

        # Set a negative balance that is more than the haircut cash claim but less than the
        # total cash claim
        benefitPreIncentive = (benefit * ratio * 1e8) / 1e10
        # Incentive cannot be above the total benefit amount
        expectedIncentive = Wei(
            min((benefitPreIncentive * REPO_INCENTIVE) / 100, benefit * REPO_INCENTIVE / 100)
        )
        benefitSubIncentive = benefitPreIncentive - expectedIncentive
        cashBalance = -Wei((totalHaircutCashClaim + fCashResidualAssetValue) + benefitSubIncentive)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, 0)

        (fc, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        # Check that the amounts are correct
        txn = liquidation.mock.calculateLocalCurrencyLiquidationTokens(
            accounts[0], currency, 0, {"from": accounts[1]}
        )

        (localAssetCashFromLiquidator, nTokensPurchased, netCashChange, portfolio) = txn.events[
            "LocalLiquidationTokens"
        ][0].values()

        # Test the liquidator side of the transaction
        # TODO: this fails...
        # assert pytest.approx(localAssetCashFromLiquidator, abs=10) == -expectedIncentive
        assert nTokensPurchased == 0

        # Set the new liquidated side of the transaction
        liquidation.mock.setPortfolioState(accounts[0], portfolio)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance + netCashChange, 0)

        (_, _, portfolioAfter) = liquidation.mock.getAccount(accounts[0])
        marketsAfter = liquidation.mock.getActiveMarkets(currency)

        # Test that the cash claims net off
        totalCashChange = marketsBefore[marketIndex - 1][3] - marketsAfter[marketIndex - 1][3]
        assert pytest.approx(totalCashChange, abs=1) == netCashChange - localAssetCashFromLiquidator

        # Test that the tokens withdrawn correspond to the ratio, within 0.5% of the ratio
        totalTokenChange = marketsBefore[marketIndex - 1][4] - marketsAfter[marketIndex - 1][4]
        # TODO: errors
        # assert pytest.approx(totalTokenChange / tokens, abs=5e-3) == min((ratio / 100), 1)

        # Test that the fCash claim was withdrawn properly, within 0.5% of the ratio
        totalfCashChange = marketsBefore[marketIndex - 1][2] - marketsAfter[marketIndex - 1][2]
        # TODO: errors
        # assert pytest.approx(totalfCashChange / totalfCashClaim, abs=5e-3) ==
        # min((ratio / 100), 1)

        finalTokenAsset = list(
            filter(lambda x: x[0] == currency and x[2] == marketIndex + 1, portfolioAfter)
        )
        finalfCashAsset = list(
            filter(
                lambda x: x[0] == currency
                and x[2] == 1
                and x[1] == marketsBefore[marketIndex - 1][1],
                portfolioAfter,
            )
        )

        # Assert portfolio updated properly, DO NOT use pytest.approx here. Must be exact.
        if totalTokenChange == tokens:
            assert len(finalTokenAsset) == 0
        else:
            assert finalTokenAsset[0][3] == tokens - totalTokenChange

        if totalfCashChange == totalfCashClaim:
            assert len(finalfCashAsset) == 0
        else:
            # Portfolio is updated with the negative side of the fcash claim
            assert finalfCashAsset[0][3] == -(totalfCashClaim - totalfCashChange)

    @pytest.mark.todo
    def test_liquidity_token_positive_available():
        pass

    @pytest.mark.todo
    def test_liquidity_token_to_ntoken_pass_through():
        pass

    @pytest.mark.todo
    def test_liquidity_token_calculate_no_changes():
        pass
