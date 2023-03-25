import logging
import random

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.test import given, strategy
from tests.internal.liquidation.liquidation_helpers import (
    ValuationMock,
    calculate_local_debt_cash_balance,
)

LOGGER = logging.getLogger(__name__)
chain = Chain()

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
        self,
        MockLocalLiquidation,
        SettleAssetsExternal,
        FreeCollateralExternal,
        FreeCollateralAtTime,
        TradingAction,
        accounts,
    ):
        SettleAssetsExternal.deploy({"from": accounts[0]})
        FreeCollateralExternal.deploy({"from": accounts[0]})
        FreeCollateralAtTime.deploy({"from": accounts[0]})
        TradingAction.deploy({"from": accounts[0]})
        return ValuationMock(accounts[0], MockLocalLiquidation)

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def get_ntoken_benefit(self, liquidation, currency, nTokenBalance, ratio, time=chain.time()):
        haircut = liquidation.calculate_ntoken_to_asset(currency, nTokenBalance, time, "haircut")
        liquidator = liquidation.calculate_ntoken_to_asset(
            currency, nTokenBalance, time, "liquidator"
        )
        benefit = liquidator - haircut

        # if cashBalance < -haircut then under fc
        # if cashBalance < -liquidator then insolvent
        # ratio of 100 == liquidator, ratio > 100 is insolvent
        cashBalance = -Wei(haircut + (benefit * ratio * 1e8) / 1e10)

        return (benefit, cashBalance, haircut)

    def validate_ntoken_price(
        self,
        liquidation,
        currency,
        localAssetCashFromLiquidator,
        nTokensPurchased,
        time=chain.time(),
    ):
        assert pytest.approx(
            localAssetCashFromLiquidator, abs=5
        ) == liquidation.calculate_ntoken_to_asset(currency, nTokensPurchased, time, "liquidator")

    def get_liquidity_token_benefit(self, totalCashClaim, totalHaircutCashClaim, ratio):
        # The amount of benefit to the account is totalCashClaim - totalHaircutCashClaim - incentive
        benefit = totalCashClaim - totalHaircutCashClaim
        # Set a negative balance that is more than the haircut cash claim but less than the
        # total cash claim
        benefitPreIncentive = (benefit * ratio * 1e8) / 1e10

        return benefitPreIncentive

    def get_liquidity_expected_outcomes(
        self, liquidation, currency, fc, netLocal, benefitsPerAsset
    ):
        # We don't use the netLocal directly here, use fc and convert back to local asset values
        # similar LiquidationHelpers.calculateLocalLiquidationUnderlyingRequired. If we don't we
        # get some significant loss of precision.
        expectedIncentive = 0
        fCashResidualPVAsset = 0
        ethRate = liquidation.mock.getETHRate(currency)
        multiple = ethRate["buffer"] if netLocal < 0 else ethRate["haircut"]
        amountRequired = liquidation.calculate_from_underlying(
            currency, liquidation.calculate_from_eth(currency, -fc) * 100 / multiple
        )
        benefitsRequired = amountRequired
        LOGGER.info("*************** start")
        LOGGER.info("amount required: {}".format(amountRequired))

        for b in reversed(benefitsPerAsset):
            if (b["benefit"] - b["maxIncentive"]) > benefitsRequired:
                # In this case we have less benefit than required, withdraw part of it
                # NOTE: this is imprecise...
                tokensToRemove = Wei(
                    Wei(Wei(b["tokens"]) * Wei(benefitsRequired))
                    / Wei(b["benefit"] - b["maxIncentive"])
                )
                portion = tokensToRemove / b["tokens"]
                LOGGER.info("portion: {}, {}, {}".format(portion, tokensToRemove, b["tokens"]))
                expectedIncentive += Wei(b["maxIncentive"] * portion)
                fCashResidualPVAsset += Wei(b["fCashResidualPVAsset"] * portion)
                benefitsRequired = 0
                break
            else:
                # In this case we will withdraw all that remains
                expectedIncentive += b["maxIncentive"]
                fCashResidualPVAsset += b["fCashResidualPVAsset"]
                benefitsRequired = benefitsRequired - b["benefit"] + b["maxIncentive"]
                LOGGER.info("benefits required: {}".format(benefitsRequired))
        realizedBenefit = amountRequired - benefitsRequired
        LOGGER.info("*************** end")

        return (expectedIncentive, fCashResidualPVAsset, realizedBenefit)

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_negative_local_available(
        self, liquidation, accounts, currency, nTokenBalance, ratio
    ):
        # Gets the benefit for liquidating the nToken and the cash balance for the given ratio
        (benefit, cashBalance, _) = self.get_ntoken_benefit(
            liquidation, currency, nTokenBalance, ratio
        )
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, nTokenBalance)

        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, 0, {"from": accounts[1]}
        )
        # Check that the price returned is correct
        self.validate_ntoken_price(
            liquidation, currency, localAssetCashFromLiquidator, nTokensPurchased
        )
        (_, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

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
            assert fcAfter >= -10
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
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000e8),
        nTokenLimit=strategy("uint", min_value=1, max_value=100_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_negative_local_available_user_limit(
        self, liquidation, accounts, currency, nTokenBalance, ratio, nTokenLimit
    ):
        # Gets the benefit for liquidating the nToken and the cash balance for the given ratio
        (benefit, cashBalance, _) = self.get_ntoken_benefit(
            liquidation, currency, nTokenBalance, ratio
        )
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, nTokenBalance)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, nTokenLimit, {"from": accounts[1]}
        )

        assert nTokensPurchased <= nTokenLimit
        # Check that the price returned is correct
        self.validate_ntoken_price(
            liquidation, currency, localAssetCashFromLiquidator, nTokensPurchased
        )

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=1, max_value=150),
    )
    def test_ntoken_positive_local_available(
        self, liquidation, accounts, currency, nTokenBalance, ratio
    ):
        (benefit, _, haircut) = self.get_ntoken_benefit(liquidation, currency, nTokenBalance, ratio)

        # Convert from nToken asset value to debt balance value
        # if (signed terms) debt cash balance < -(benefit + nTokenHaircutValue) then insolvent
        # if -(benefit + nTokenHaircutValue) < debt cash balance < 0 then ok
        (debtCurrency, debtCashBalance) = calculate_local_debt_cash_balance(
            liquidation, currency, ratio, benefit, haircut, chain.time()
        )

        # Set the proper balances
        liquidation.mock.setBalance(accounts[0], currency, 0, nTokenBalance)
        liquidation.mock.setBalance(accounts[0], debtCurrency, debtCashBalance, 0)
        (
            localAssetCashFromLiquidator,
            nTokensPurchased,
        ) = liquidation.mock.calculateLocalCurrencyLiquidation.call(
            accounts[0], currency, 0, {"from": accounts[1]}
        )
        # Check that the price is correct
        self.validate_ntoken_price(
            liquidation, currency, localAssetCashFromLiquidator, nTokensPurchased
        )
        (_, netLocal) = liquidation.mock.getFreeCollateral(accounts[0])

        # Simulate the transfer above and check the FC afterwards
        liquidation.mock.setBalance(
            accounts[0], currency, localAssetCashFromLiquidator, nTokenBalance - nTokensPurchased
        )
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0])

        nTokenNetLocal = netLocal[0] if currency < debtCurrency else netLocal[1]
        nTokenNetLocalAfter = netLocalAfter[0] if currency < debtCurrency else netLocalAfter[1]

        if ratio <= 40:
            # In the case that the ratio is less than 40%, we liquidate up to 40%
            assert (
                pytest.approx(Wei(nTokenNetLocal + benefit * 0.40), abs=10) == nTokenNetLocalAfter
            )
            assert fcAfter >= -10
        elif ratio > 100:
            # In this scenario we liquidate all the nTokens and are still undercollateralized
            assert nTokenBalance == nTokensPurchased
            assert pytest.approx(Wei(nTokenNetLocal + benefit), abs=10) == nTokenNetLocalAfter
            assert fcAfter < 0
        else:
            # In this case the benefit is proportional to the amount liquidated
            benefit = Wei((benefit * nTokensPurchased) / nTokenBalance)
            assert pytest.approx(Wei(nTokenNetLocal + benefit), abs=10) == nTokenNetLocalAfter
            assert -5000 <= fcAfter and fcAfter <= 0

    @given(
        nTokenBalance=strategy("uint", min_value=1e8, max_value=100_000e8),
        nTokenLimit=strategy("uint", min_value=1, max_value=100_000e8),
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=10, max_value=150),
    )
    def test_ntoken_positive_local_available_user_limit(
        self, liquidation, accounts, currency, nTokenBalance, nTokenLimit, ratio
    ):
        (benefit, _, haircut) = self.get_ntoken_benefit(liquidation, currency, nTokenBalance, ratio)
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
        debtETHRate = liquidation.mock.getETHRate(debtCurrency)
        debtCashBalance = liquidation.calculate_from_underlying(
            debtCurrency, Wei((debtInUnderlyingBuffered * 100) / debtETHRate["buffer"])
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
        self.validate_ntoken_price(
            liquidation, currency, localAssetCashFromLiquidator, nTokensPurchased
        )

    @given(
        debtBalance=strategy("uint", min_value=1e8, max_value=100_000e8),
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
        debtBalance=strategy("uint", min_value=10_000e8, max_value=100_000e8),
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

    @pytest.mark.skip
    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=5, max_value=150),
        numTokens=strategy("uint", min_value=1, max_value=3),
        totalCashClaim=strategy("uint", min_value=100e8, max_value=10_000_000e8),
    )
    def test_liquidity_token_negative_available(
        self, liquidation, accounts, currency, ratio, numTokens, totalCashClaim
    ):
        marketsBefore = liquidation.mock.getActiveMarkets(currency)
        blockTime = chain.time()
        # Will generate matching fCash and shares
        (
            assets,
            totalCashClaim,  # This is recalculated from the tokens
            totalHaircutCashClaim,
            totalfCashResidual,
            totalHaircutfCashResidual,
            benefitsPerAsset,
        ) = liquidation.get_liquidity_tokens(currency, totalCashClaim, numTokens, blockTime)
        liquidation.mock.setPortfolio(accounts[0], assets)

        # Get the expected benefit and incentive paid
        benefitPreIncentive = self.get_liquidity_token_benefit(
            totalCashClaim, totalHaircutCashClaim, ratio
        )

        cashBalance = -Wei(
            (totalHaircutCashClaim + totalHaircutfCashResidual) + benefitPreIncentive
        )
        liquidation.mock.setBalance(accounts[0], currency, cashBalance, 0)

        # FC here is -(benefitPreIncentive * buffer)
        (fc, netLocalBefore) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)

        # Returns the expected
        (
            expectedIncentive,
            fCashResidualPVAsset,
            realizedBenefit,
        ) = self.get_liquidity_expected_outcomes(
            liquidation, currency, fc, netLocalBefore[0], benefitsPerAsset
        )

        # Check that the amounts are correct
        txn = liquidation.mock.calculateLocalCurrencyLiquidationTokens(
            accounts[0], currency, 0, {"from": accounts[1]}
        )

        (localAssetCashFromLiquidator, nTokensPurchased, netCashChange, portfolio) = txn.events[
            "LocalLiquidationTokens"
        ][0].values()

        # Set the new liquidated side of the transaction
        liquidation.mock.setPortfolioState(accounts[0], portfolio)
        liquidation.mock.setBalance(accounts[0], currency, cashBalance + netCashChange, 0)

        (_, _, portfolioAfter) = liquidation.mock.getAccount(accounts[0])
        marketsAfter = liquidation.mock.getActiveMarkets(currency)

        # This checks that the tokens and fCash withdrawn align with markets exactly
        totalCashChange = liquidation.validate_market_changes(
            assets, portfolioAfter, marketsBefore, marketsAfter
        )

        # Test that the cash claims net off
        assert pytest.approx(totalCashChange, abs=1) == netCashChange - localAssetCashFromLiquidator
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)

        # Test the liquidator side of the transaction
        assert nTokensPurchased == 0
        assert pytest.approx(localAssetCashFromLiquidator, rel=500) == -expectedIncentive

        # Assert that the net local after is equal to the fcash residual withdrawn plus the net
        # benefit
        # TODO: this is incorrect
        # assert pytest.approx(netLocalAfter[0] - netLocalBefore[0], rel=1e-6, abs=500) == (
        #     fCashResidualPVAsset + realizedBenefit
        # )
        assert fcAfter > 0

    @pytest.mark.skip
    @given(
        currency=strategy("uint", min_value=1, max_value=4),
        ratio=strategy("uint", min_value=5, max_value=150),
        numTokens=strategy("uint", min_value=1, max_value=3),
        totalCashClaim=strategy("uint", min_value=100e8, max_value=10_000_000e8),
    )
    def test_liquidity_token_positive_available(
        self, liquidation, accounts, currency, ratio, numTokens, totalCashClaim
    ):
        # Choose a random currency for the debt to be in
        debtCurrency = random.choice([c for c in range(1, 5) if c != currency])
        marketsBefore = liquidation.mock.getActiveMarkets(currency)
        blockTime = chain.time()

        # Will generate matching fCash and shares
        (
            assets,
            totalCashClaim,  # This is recalculated from the tokens
            totalHaircutCashClaim,
            totalfCashResidual,
            totalHaircutfCashResidual,
            benefitsPerAsset,
        ) = liquidation.get_liquidity_tokens(currency, totalCashClaim, numTokens, blockTime)
        liquidation.mock.setPortfolio(accounts[0], assets)

        # Get the expected benefit and incentive paid
        benefitPreIncentive = self.get_liquidity_token_benefit(
            totalCashClaim, totalHaircutCashClaim, ratio
        )

        benefitInETH = liquidation.calculate_to_eth(
            currency, liquidation.calculate_to_underlying(currency, benefitPreIncentive)
        )

        haircutInETH = liquidation.calculate_to_eth(
            currency,
            liquidation.calculate_to_underlying(
                currency, Wei(totalHaircutCashClaim + totalHaircutfCashResidual)
            ),
        )

        # This is the amount of debt post buffer we can offset with the benefit in ETH
        debtInUnderlyingBuffered = liquidation.calculate_from_eth(
            debtCurrency, benefitInETH + haircutInETH
        )
        # Undo the buffer when calculating the cash balance
        debtETHRate = liquidation.mock.getETHRate(debtCurrency)
        debtCashBalance = liquidation.calculate_from_underlying(
            debtCurrency, Wei((debtInUnderlyingBuffered * 100) / debtETHRate["buffer"])
        )

        liquidation.mock.setBalance(accounts[0], debtCurrency, -debtCashBalance, 0)
        (fc, netLocalBefore) = liquidation.mock.getFreeCollateralAtTime(accounts[0], blockTime)

        (
            expectedIncentive,
            fCashResidualPVAsset,
            realizedBenefit,
        ) = self.get_liquidity_expected_outcomes(
            liquidation, currency, fc, netLocalBefore[0], benefitsPerAsset
        )

        # Check that the amounts are correct
        txn = liquidation.mock.calculateLocalCurrencyLiquidationTokens(
            accounts[0], currency, 0, {"from": accounts[1]}
        )

        (localAssetCashFromLiquidator, nTokensPurchased, netCashChange, portfolio) = txn.events[
            "LocalLiquidationTokens"
        ][0].values()

        liquidation.mock.setPortfolioState(accounts[0], portfolio)
        liquidation.mock.setBalance(accounts[0], currency, netCashChange, 0)

        (_, _, portfolioAfter) = liquidation.mock.getAccount(accounts[0])
        marketsAfter = liquidation.mock.getActiveMarkets(currency)

        # This checks that the tokens and fCash withdrawn align with markets exactly
        totalCashChange = liquidation.validate_market_changes(
            assets, portfolioAfter, marketsBefore, marketsAfter
        )

        # Test that the cash claims net off
        assert pytest.approx(totalCashChange, abs=1) == netCashChange - localAssetCashFromLiquidator
        (fcAfter, netLocalAfter) = liquidation.mock.getFreeCollateral(accounts[0])

        # Test the liquidator side of the transaction
        assert nTokensPurchased == 0

        assert pytest.approx(localAssetCashFromLiquidator, rel=500) == -expectedIncentive

        # Assert that the net local after is equal to the fcash residual withdrawn
        # TODO: what is the net local after withdrawing tokens?
        # assert pytest.approx(netLocalAfter[0], abs=100) == fCashResidualPVAsset
        assert fcAfter > 0

    @pytest.mark.skip
    def test_liquidity_token_to_ntoken_pass_through():
        pass
