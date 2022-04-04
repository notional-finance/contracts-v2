import random

import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from hypothesis import settings
from scripts.config import CurrencyDefaults
from scripts.deployment import TestEnvironment, TokenType
from tests.helpers import currencies_list_to_active_currency_bytes, get_balance_state

DAI_CURRENCY_ID = 7


@pytest.mark.balances
class TestBalanceHandler:
    @pytest.fixture(scope="module", autouse=True)
    def balanceHandler(self, MockBalanceHandler, MigrateIncentives, MockERC20, accounts):
        MigrateIncentives.deploy({"from": accounts[0]})
        handler = MockBalanceHandler.deploy({"from": accounts[0]})
        # Ensure that we have at least 2 bytes of currencies
        handler.setMaxCurrencyId(6)
        return handler

    @pytest.fixture(scope="module", autouse=True)
    def tokens(self, balanceHandler, MockERC20, accounts):
        tokens = []
        for i in range(1, 7):
            hasFee = i in [1, 2, 3]
            decimals = [6, 8, 18, 6, 8, 18][i - 1]
            fee = Wei(0.01e18) if hasFee else 0

            token = MockERC20.deploy(str(i), str(i), decimals, fee, {"from": accounts[0]})
            balanceHandler.setCurrencyMapping(
                i, False, (token.address, hasFee, TokenType["NonMintable"], decimals, 0)
            )
            token.approve(balanceHandler.address, 2 ** 255, {"from": accounts[0]})
            token.transfer(balanceHandler.address, 10 ** decimals * 10e18, {"from": accounts[0]})
            tokens.append(token)

        return tokens

    @pytest.fixture(scope="module", autouse=True)
    def cTokenEnvironment(self, balanceHandler, accounts):
        env = TestEnvironment(accounts[0])
        env.enableCurrency("DAI", CurrencyDefaults)
        currencyId = DAI_CURRENCY_ID
        balanceHandler.setCurrencyMapping(
            currencyId, True, (env.token["DAI"].address, False, TokenType["UnderlyingToken"], 18, 0)
        )
        balanceHandler.setCurrencyMapping(
            currencyId, False, (env.cToken["DAI"].address, False, TokenType["cToken"], 8, 0)
        )
        env.token["DAI"].approve(balanceHandler.address, 2 ** 255, {"from": accounts[0]})
        env.cToken["DAI"].approve(balanceHandler.address, 2 ** 255, {"from": accounts[0]})

        return env

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    @given(
        currencyId=strategy("uint", min_value=1, max_value=6),
        assetBalance=strategy("int88", min_value=-10e18, max_value=10e18),
        nTokenBalance=strategy("uint80", max_value=10e18),
    )
    def test_set_and_load_balance_handler(
        self, balanceHandler, accounts, currencyId, assetBalance, nTokenBalance
    ):
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, assetBalance, nTokenBalance)
        context = (0, "0x00", 0, 0, active_currencies)

        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)
        assert bs[0] == currencyId
        assert bs[1] == assetBalance
        assert bs[2] == nTokenBalance
        # Incentive claim factors don't come into play here
        assert bs[3] == 0
        assert bs[4] == 0

    @given(
        nTokenBalance=strategy("uint80", max_value=10e18),
        netNTokenSupplyChange=strategy("int88", min_value=-10e18, max_value=10e18),
    )
    @settings(max_examples=10)
    def test_finalize_cannot_withdraw_to_negative_ntoken(
        self, balanceHandler, accounts, nTokenBalance, netNTokenSupplyChange
    ):
        currencyId = 1
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, 0, nTokenBalance)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        bsCopy[6] = netNTokenSupplyChange
        # netNTokenTransfer
        if nTokenBalance + netNTokenSupplyChange >= 0:
            bsCopy[5] = -(nTokenBalance + netNTokenSupplyChange + random.randint(1, 1e8))
            with brownie.reverts("Neg nToken"):
                balanceHandler.finalize(bsCopy, accounts[0], context, False)
        else:
            with brownie.reverts():
                balanceHandler.finalize(bsCopy, accounts[0], context, False)

    @given(
        assetBalance=strategy("int88", min_value=-10e18, max_value=10e18),
        netCashChange=strategy("int88", min_value=-10e18, max_value=10e18),
    )
    @settings(max_examples=10)
    def test_finalize_cannot_withdraw_to_negative_cash(
        self, balanceHandler, accounts, assetBalance, netCashChange
    ):
        currencyId = 1
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, assetBalance, 0)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        bsCopy[3] = netCashChange
        if assetBalance + netCashChange >= 0:
            bsCopy[4] = -(assetBalance + netCashChange + random.randint(1, 1e8))
        else:
            bsCopy[4] = -random.randint(1, 1e8)

        with brownie.reverts("Neg Cash"):
            balanceHandler.finalize(bsCopy, accounts[0], context, False)

    @pytest.mark.skip
    @given(nTokenBalance=strategy("uint80", min_value=1e8, max_value=10e18))
    @settings(max_examples=10)
    def test_ntoken_transfer_sets_incentives(self, balanceHandler, accounts, nTokenBalance):
        currencyId = 1
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, 0, nTokenBalance)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        # This should result in a valid transfer
        bsCopy[5] = random.randint(-nTokenBalance, nTokenBalance)
        txn = balanceHandler.finalize(bsCopy, accounts[0], context, False)
        (bs_, _) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        assert bs_[0] == currencyId
        assert bs_[1] == 0
        assert bs_[2] == nTokenBalance + bsCopy[5]
        assert bs_[7] == 0 if bsCopy[5] == 0 else txn.timestamp
        # Integral supply will always be set to zero since we're not properly
        # initializing supply here
        assert bs_[8] == 0

    @pytest.mark.skip
    @given(nTokenBalance=strategy("uint80", min_value=1e8, max_value=10e18))
    @settings(max_examples=20)
    def test_ntoken_supply_change_sets_incentives(self, balanceHandler, accounts, nTokenBalance):
        currencyId = 1
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, 0, nTokenBalance)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        # This should result in a valid supply change
        bsCopy[6] = random.randint(-nTokenBalance, nTokenBalance)
        # TODO: nToken supply change will fail here
        txn = balanceHandler.finalize(bsCopy, accounts[0], context, False)
        (bs_, _) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        assert bs_[0] == currencyId
        assert bs_[1] == 0
        assert bs_[2] == nTokenBalance + bsCopy[6]
        assert bs_[7] == 0 if bsCopy[6] == 0 else txn.timestamp
        # Integral supply will always be set to zero since we're not properly
        # initializing supply here
        assert bs_[8] == 0

    @given(
        assetBalance=strategy("int88", min_value=1e8, max_value=10e18),
        currencyId=strategy("uint8", min_value=4, max_value=6),
    )
    @settings(max_examples=25)
    def test_balance_transfer_no_fee_no_dust(
        self, balanceHandler, accounts, currencyId, assetBalance, tokens
    ):
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, assetBalance, 0)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        # This should result in a valid asset transfer
        bsCopy[4] = random.randint(-assetBalance, assetBalance)

        balanceBefore = tokens[currencyId - 1].balanceOf(balanceHandler.address)
        txn = balanceHandler.finalize(bsCopy, accounts[0], context, False)
        balanceAfter = tokens[currencyId - 1].balanceOf(balanceHandler.address)
        (context_, transferAmountExternal) = txn.return_value
        (bs_, _) = balanceHandler.loadBalanceState(accounts[0], currencyId, context_)

        currency = balanceHandler.getCurrencyMapping(currencyId, False)
        if currency[2] < 1e8 and bsCopy[4] > 0:
            if bsCopy[4] < 100:
                assert bs_[1] == bsCopy[1]
                assert transferAmountExternal == 0
                assert balanceBefore == balanceAfter
            else:
                # Dust can accrue in the lower part with 6 decimal precision due to truncation so we
                # modify the cash balances credited to users by 1 here
                assert bs_[1] == bsCopy[1] + balanceHandler.convertToInternal(
                    currencyId, balanceHandler.convertToExternal(currencyId, bsCopy[4])
                )
                assert balanceAfter - balanceBefore == transferAmountExternal
                assert transferAmountExternal == balanceHandler.convertToExternal(
                    currencyId, bsCopy[4]
                )
        elif currency[2] < 1e8:
            if bsCopy[4] > -100:
                assert bs_[1] == bsCopy[1]
                assert transferAmountExternal == 0
                assert balanceBefore == balanceAfter
            else:
                assert bs_[1] == bsCopy[1] + balanceHandler.convertToInternal(
                    currencyId, balanceHandler.convertToExternal(currencyId, bsCopy[4])
                )
                assert balanceAfter - balanceBefore == transferAmountExternal
                assert transferAmountExternal == balanceHandler.convertToExternal(
                    currencyId, bsCopy[4]
                )
        else:
            assert bs_[1] == bsCopy[1] + bsCopy[4]
            assert balanceAfter - balanceBefore == transferAmountExternal
            assert transferAmountExternal == balanceHandler.convertToExternal(currencyId, bsCopy[4])

    @given(
        assetBalance=strategy("int88", min_value=1e8, max_value=10e18),
        currencyId=strategy("uint8", min_value=1, max_value=3),
    )
    @settings(max_examples=25)
    def test_balance_transfer_has_fee(
        self, balanceHandler, accounts, currencyId, assetBalance, tokens
    ):
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, assetBalance, 0)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        # This should result in a valid asset transfer
        bsCopy[4] = random.randint(-assetBalance, assetBalance)

        balanceBefore = tokens[currencyId - 1].balanceOf(balanceHandler.address)
        txn = balanceHandler.finalize(bsCopy, accounts[0], context, False)
        balanceAfter = tokens[currencyId - 1].balanceOf(balanceHandler.address)
        (context_, transferAmountExternal) = txn.return_value
        (bs_, _) = balanceHandler.loadBalanceState(accounts[0], currencyId, context_)

        currency = balanceHandler.getCurrencyMapping(currencyId, False)
        assert bs_[1] == bsCopy[1] + balanceHandler.convertToInternal(
            currencyId, transferAmountExternal
        )

        if currency[2] < 1e8 and bsCopy[4] > 0:
            assert balanceAfter - balanceBefore == transferAmountExternal
        else:
            assert balanceAfter - balanceBefore == transferAmountExternal

    @given(
        assetBalance=strategy("int88", min_value=-10e8, max_value=10e18),
        netCashChange=strategy("int88", min_value=-10e8, max_value=10e18),
    )
    @settings(max_examples=10)
    def test_set_net_cash_change_has_debt(
        self, balanceHandler, accounts, assetBalance, netCashChange
    ):
        currencyId = 1
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        balanceHandler.setBalance(accounts[0], currencyId, assetBalance, 0)
        context = (0, "0x00", 0, 0, active_currencies)
        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        bsCopy = list(bs)
        bsCopy[3] = netCashChange
        txn = balanceHandler.finalize(bsCopy, accounts[0], context, False)
        (context_, _) = txn.return_value
        (bs_, _) = balanceHandler.loadBalanceState(accounts[0], currencyId, context_)

        assert bs_[1] == bsCopy[1] + bsCopy[3]
        if bs_[1] < 0:
            assert context_[1] == "0x02"
        else:
            assert context_[1] == "0x00"

    @pytest.mark.todo
    def test_finalize_settle_amounts(self, balanceHandler, accounts):
        pass

    @given(
        currencyId=strategy("uint", min_value=1, max_value=6),
        assetBalance=strategy("int88", min_value=-10e18, max_value=10e18),
        netCashChange=strategy("int88", min_value=-10e18, max_value=10e18),
        netTransfer=strategy("int88", min_value=-10e18, max_value=10e18),
    )
    @settings(max_examples=10)
    def test_deposit_asset_token(
        self, balanceHandler, tokens, accounts, currencyId, assetBalance, netCashChange, netTransfer
    ):
        assetDeposit = int(100e8)
        tolerance = 2
        bs = get_balance_state(
            currencyId,
            storedCashBalance=assetBalance,
            netCashChange=netCashChange,
            netAssetTransferInternalPrecision=netTransfer,
        )

        currency = balanceHandler.getCurrencyMapping(currencyId, False)
        assetDepositExternal = balanceHandler.convertToExternal(currencyId, assetDeposit)

        if currency[1]:
            # Has transfer fee
            fee = assetDepositExternal // 100
            # Asset deposit in internal precision post fee
            assetDeposit = balanceHandler.convertToInternal(currencyId, assetDepositExternal - fee)

        # without cash balance, should simply be a deposit into the account, only transfer
        # amounts change
        balanceBefore = tokens[currencyId - 1].balanceOf(balanceHandler.address)
        txn = balanceHandler.depositAssetToken(bs, accounts[0], assetDepositExternal, False)
        balanceAfter = tokens[currencyId - 1].balanceOf(balanceHandler.address)
        (newBalanceState, assetAmountInternal) = txn.return_value

        # Need to truncate precision difference
        if currency[2] < 1e8 and currency[1]:
            assetDepositAdjusted = balanceHandler.convertToInternal(
                currencyId, balanceHandler.convertToExternal(currencyId, assetDeposit)
            )
        else:
            assetDepositAdjusted = assetDeposit

        assert (newBalanceState[1] + newBalanceState[3] + newBalanceState[4]) == (
            assetBalance + netCashChange + netTransfer + assetDepositAdjusted
        )

        if currency[1]:
            # Token has a fee then the transfer as occurred
            assert (
                pytest.approx(balanceAfter - balanceBefore, abs=tolerance)
                == assetDepositExternal - fee
            )
            assert (
                pytest.approx(newBalanceState[3], abs=tolerance)
                == netCashChange + assetDepositAdjusted
            )
        else:
            assert balanceBefore == balanceAfter
            assert (
                pytest.approx(newBalanceState[4], abs=tolerance)
                == netTransfer + assetDepositAdjusted
            )

        assert assetAmountInternal == assetDepositAdjusted

    @given(underlyingAmount=strategy("int88", min_value=0, max_value=10e18))
    @settings(max_examples=10)
    def test_deposit_and_withdraw_underlying_asset_token(
        self, balanceHandler, cTokenEnvironment, accounts, underlyingAmount
    ):
        # deposit asset tokens
        currencyId = DAI_CURRENCY_ID
        underlyingBalanceBefore = cTokenEnvironment.token["DAI"].balanceOf(balanceHandler.address)
        balanceBefore = cTokenEnvironment.cToken["DAI"].balanceOf(balanceHandler.address)

        bs = get_balance_state(currencyId)
        txn = balanceHandler.depositUnderlyingToken(bs, accounts[0], underlyingAmount)

        balanceAfter = cTokenEnvironment.cToken["DAI"].balanceOf(balanceHandler.address)
        underlyingBalanceAfter = cTokenEnvironment.token["DAI"].balanceOf(balanceHandler.address)

        # test balance after
        (newBalanceState, assetTokensReceived) = txn.return_value

        assert balanceAfter - balanceBefore == assetTokensReceived
        assert underlyingBalanceBefore == underlyingBalanceAfter
        assert assetTokensReceived == newBalanceState[3]

        # withdraw asset
        balanceBefore = cTokenEnvironment.cToken["DAI"].balanceOf(balanceHandler.address)
        underlyingBalanceBefore = cTokenEnvironment.token["DAI"].balanceOf(balanceHandler.address)
        accountUnderlyingBalanceBefore = cTokenEnvironment.token["DAI"].balanceOf(
            accounts[0].address
        )

        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        context = (0, "0x00", 0, 0, active_currencies)
        # withdraw all the asset tokens received
        bs = get_balance_state(
            currencyId,
            storedCashBalance=assetTokensReceived,
            netAssetTransferInternalPrecision=-assetTokensReceived,
        )
        txn = balanceHandler.finalize(bs, accounts[0], context, True)

        underlyingBalanceAfter = cTokenEnvironment.token["DAI"].balanceOf(balanceHandler.address)
        balanceAfter = cTokenEnvironment.cToken["DAI"].balanceOf(balanceHandler.address)
        accountUnderlyingBalanceAfter = cTokenEnvironment.token["DAI"].balanceOf(
            accounts[0].address
        )

        assert balanceBefore - balanceAfter == assetTokensReceived
        # balance handler should not have any net underlying balance
        assert underlyingBalanceBefore == underlyingBalanceAfter
        if assetTokensReceived > 0:
            assert accountUnderlyingBalanceAfter > accountUnderlyingBalanceBefore

    def test_redeem_to_underlying(self, balanceHandler, accounts, cTokenEnvironment):
        currencyId = DAI_CURRENCY_ID
        cTokenEnvironment.token["DAI"].approve(
            cTokenEnvironment.cToken["DAI"].address, 2 ** 255, {"from": accounts[0]}
        )
        cTokenEnvironment.cToken["DAI"].mint(10000e18, {"from": accounts[0]})
        cTokenEnvironment.cToken["DAI"].transfer(
            balanceHandler.address, 200e8, {"from": accounts[0]}
        )
        active_currencies = currencies_list_to_active_currency_bytes([(currencyId, False, True)])
        context = (0, "0x00", 0, 0, active_currencies)

        (bs, context) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)
        bsCopy = list(bs)
        bsCopy[1] = Wei(100e8)
        bsCopy[4] = Wei(-100e8)

        cTokenBalanceBefore = cTokenEnvironment.cToken["DAI"].balanceOf(accounts[0])
        daiBalanceBefore = cTokenEnvironment.token["DAI"].balanceOf(accounts[0])
        balanceHandler.finalize(bsCopy, accounts[0], context, True)
        (bsAfter, _) = balanceHandler.loadBalanceState(accounts[0], currencyId, context)

        cTokenBalanceAfter = cTokenEnvironment.cToken["DAI"].balanceOf(accounts[0])
        daiBalanceAfter = cTokenEnvironment.token["DAI"].balanceOf(accounts[0])
        contractDaiBalanceAfter = cTokenEnvironment.token["DAI"].balanceOf(balanceHandler.address)
        contractCTokenBalanceAfter = cTokenEnvironment.cToken["DAI"].balanceOf(
            balanceHandler.address
        )

        assert bsAfter[1] == 0
        assert cTokenBalanceBefore - cTokenBalanceAfter == 0
        assert daiBalanceAfter - daiBalanceBefore == 2e18
        assert cTokenBalanceBefore - cTokenBalanceAfter == 0
        assert contractDaiBalanceAfter == 0
        assert contractCTokenBalanceAfter == 100e8
