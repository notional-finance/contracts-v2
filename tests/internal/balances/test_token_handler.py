import math
import brownie
import pytest
from brownie import Contract, accounts
from brownie.convert.datatypes import HexString, Wei
from brownie.network import Chain, Rpc
from brownie.test import given, strategy
from scripts.deployment import TokenType, deployNoteERC20
from tests.constants import FEE_RESERVE, HAS_CASH_DEBT, SECONDS_IN_QUARTER
from tests.helpers import (
    currencies_list_to_active_currency_bytes,
    get_balance_state,
    get_interest_rate_curve,
)

chain = Chain()
rpc = Rpc()
zeroAddress = HexString(0, type_str="bytes20")


@pytest.mark.balances
class TestTokenHandler:
    @pytest.fixture(scope="module", autouse=True)
    def tokenHandler(self, MockTokenHandler, MigrateIncentives, MockSettingsLib, accounts):
        MigrateIncentives.deploy({"from": accounts[0]})
        settingsLib = MockSettingsLib.deploy({"from": accounts[0]})
        mock = MockTokenHandler.deploy(settingsLib, {"from": accounts[0]})
        return Contract.from_abi(
            "mock", mock.address, MockSettingsLib.abi + mock.abi, owner=accounts[0]
        )

    @pytest.fixture(scope="module", autouse=True)
    def weth(self, MockWETH):
        wethDeployer = accounts.at("0x4f26ffbe5f04ed43630fdc30a87638d53d0b0876", force=True)
        rpc.backend._request(
            "evm_setAccountNonce", ["0x4f26ffbe5f04ed43630fdc30a87638d53d0b0876", 446]
        )
        return MockWETH.deploy({"from": wethDeployer})

    @pytest.fixture(scope="module")
    def tokens(self, tokenHandler, MockERC20, MockCToken, CompoundV2HoldingsOracle, MockCTokenAssetRateAdapter, accounts):
        ETH = zeroAddress
        USDC = MockERC20.deploy("USDC", "USDC", 6, 0, {"from": accounts[0]})
        DAI = MockERC20.deploy("DAI", "DAI", 18, 0, {"from": accounts[0]})
        NODEBT = MockERC20.deploy("NODEBT", "NODEBT", 18, 0, {"from": accounts[0]})

        tokens = [ETH, USDC, DAI, NODEBT]
        cTokens = []
        oracles = []

        for (i, t) in enumerate(tokens):
            decimals = 18 if i == 0 else t.decimals()
            cToken = MockCToken.deploy(8, {"from": accounts[0]})
            assetRate = MockCTokenAssetRateAdapter.deploy(cToken.address, {"from": accounts[0]})
            cToken.setUnderlying(t)

            cToken.setAnswer(0.02 * 10 ** (18 + (decimals - 8)))
            oracle = CompoundV2HoldingsOracle.deploy((tokenHandler.address, t, cToken.address, assetRate.address), {"from": accounts[0]})

            if t == ETH:
                accounts[9].transfer(cToken, 9_999e18)
                # make this some ratio of cTokens....
                accounts[0].transfer(tokenHandler, 100e18)
                tokenHandler.setToken(
                    i + 1, (ETH, False, TokenType["Ether"], 18, 0), {"from": accounts[0]}
                )
            else:
                t.transfer(cToken, 1_000 * (10 ** t.decimals()))
                t.transfer(tokenHandler, 100 * (10 ** t.decimals()))
                tokenHandler.setToken(
                    i + 1,
                    (t, t.transferFee() > 0, TokenType["UnderlyingToken"], t.decimals(), 0),
                    {"from": accounts[0]},
                )
                t.approve(tokenHandler, 2 ** 255, {"from": accounts[0]})

            cTokens.append(cToken)
            oracles.append(oracle)

            # Token Handler has 100 units of underlying and 900 units of cTokens
            cToken.transfer(tokenHandler, 45_000e8, {"from": accounts[0]})
            tokenHandler.initPrimeCashCurve(
                i + 1,
                1_000e8,
                0,
                get_interest_rate_curve(),
                oracle,
                i != 3,  # 3 = NODEBT token
                {"from": accounts[0]},
            )

        return {"tokens": tokens, "cTokens": cTokens, "oracles": oracles, "handler": tokenHandler}

    @pytest.fixture(autouse=True)
    def isolation(self, fn_isolation):
        pass

    def test_cannot_set_eth_twice(self, tokenHandler, accounts, MockERC20):
        zeroAddress = HexString(0, "bytes20")
        tokenHandler.setToken(1, (zeroAddress, False, TokenType["Ether"], 18, 0))
        erc20 = MockERC20.deploy("Ether", "Ether", 18, 0, {"from": accounts[0]})

        with brownie.reverts():
            tokenHandler.setToken(2, (erc20.address, False, TokenType["Ether"], 18, 0))

        with brownie.reverts("TH: address is zero"):
            tokenHandler.setToken(2, (zeroAddress, False, TokenType["UnderlyingToken"], 18, 0))

    def test_cannot_override_token(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        erc20_ = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        tokenHandler.setToken(2, (erc20.address, False, TokenType["UnderlyingToken"], 18, 0))

        with brownie.reverts("TH: token cannot be reset"):
            tokenHandler.setToken(2, (erc20_.address, False, TokenType["UnderlyingToken"], 18, 0))

    def test_cannot_set_asset_to_underlying(self, tokenHandler, accounts, MockERC20):
        erc20 = MockERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})

        with brownie.reverts():
            tokenHandler.setToken(2, (erc20.address, False, TokenType["cToken"], 18, 0))

    def test_deposit_respects_max_supply(self, tokens, accounts):
        tokenHandler = tokens["handler"]
        for (i, t) in enumerate(tokens["tokens"]):
            tokenHandler.setMaxUnderlyingSupply(i + 1, 1500e8)
            decimals = 18 if i == 0 else t.decimals()
            balanceBefore = tokens["oracles"][i].getTotalUnderlyingValueView()
            depositExternal = Wei(400 * (10 ** decimals))

            tokenHandler.depositUnderlyingExternal(
                accounts[0],
                i + 1,
                depositExternal,
                False,
                {"from": accounts[0], "value": depositExternal if i == 0 else 0},
            )

            balanceAfter = tokens["oracles"][i].getTotalUnderlyingValueView()
            assert balanceAfter[0] - balanceBefore[0] == depositExternal
            assert balanceAfter[1] - balanceBefore[1] == Wei(400e8)

            with brownie.reverts("Over Supply Cap"):
                tokenHandler.depositUnderlyingExternalCheckSupply(
                    accounts[0],
                    i + 1,
                    depositExternal,
                    False,
                    {"from": accounts[0], "value": depositExternal if i == 0 else 0},
                )

            # Reduce supply balance
            tokenHandler.setMaxUnderlyingSupply(i + 1, 1200e8)

            # Still cannot deposit
            with brownie.reverts("Over Supply Cap"):
                tokenHandler.depositUnderlyingExternalCheckSupply(
                    accounts[0],
                    i + 1,
                    depositExternal,
                    False,
                    {"from": accounts[0], "value": depositExternal if i == 0 else 0},
                )

            # Can withdraw above collateral balance
            withdrawExternal = Wei(-1 * (10 ** decimals))
            adjustment = 1e10 if decimals == 18 else 0
            (pr, _) = tokenHandler.buildPrimeRateView(i + 1, chain.time())
            withdrawPCash = tokenHandler.convertFromUnderlying(pr, -1e8)
            balanceBefore = tokens["oracles"][i].getTotalUnderlyingValueView()
            tokenHandler.withdrawPrimeCash(
                accounts[0], i + 1, withdrawPCash, False, {"from": accounts[0]}
            )
            balanceAfter = tokens["oracles"][i].getTotalUnderlyingValueView()
            assert pytest.approx(balanceAfter[0] - balanceBefore[0], abs=adjustment) == withdrawExternal
            assert pytest.approx(balanceAfter[1] - balanceBefore[1], abs=1) == Wei(-1e8)

            # Can withdraw below collateral balance
            withdrawExternal = Wei(-399 * (10 ** decimals))
            (pr, _) = tokenHandler.buildPrimeRateView(i + 1, chain.time())
            withdrawPCash = tokenHandler.convertFromUnderlying(pr, -399e8)
            balanceBefore = tokens["oracles"][i].getTotalUnderlyingValueView()
            tokenHandler.withdrawPrimeCash(
                accounts[0], i + 1, withdrawPCash, False, {"from": accounts[0]}
            )
            balanceAfter = tokens["oracles"][i].getTotalUnderlyingValueView()
            assert pytest.approx(balanceAfter[0] - balanceBefore[0], abs=adjustment) == withdrawExternal
            assert pytest.approx(balanceAfter[1] - balanceBefore[1], abs=1) == Wei(-399e8)

            # Can now deposit again
            depositExternal = Wei(100 * (10 ** decimals))
            tokenHandler.depositUnderlyingExternalCheckSupply(
                accounts[0],
                i + 1,
                depositExternal,
                False,
                {"from": accounts[0], "value": depositExternal if i == 0 else 0},
            )

    def test_token_transfer_returns_false(self, tokens, accounts):
        tokenHandler = tokens["handler"]
        token = tokens["tokens"][1]

        # Deposit a bit for the withdraw
        tokenHandler.depositUnderlyingExternal(accounts[0].address, 2, 100e18, False)

        token.setTransferReturnValue(False)
        with brownie.reverts():
            tokenHandler.depositUnderlyingExternal(accounts[0].address, 2, 100, False)

        with brownie.reverts():
            tokenHandler.depositExactToMintPrimeCash(accounts[0].address, 2, 100, False)

        with brownie.reverts():
            tokenHandler.withdrawPrimeCash(accounts[0].address, 2, -100, False)

    def test_non_compliant_token(
        self, tokenHandler, MockNonCompliantERC20, MockCToken, CompoundV2HoldingsOracle, accounts, MockCTokenAssetRateAdapter
    ):
        erc20 = MockNonCompliantERC20.deploy("test", "TEST", 18, 0, {"from": accounts[0]})
        tokenHandler.setToken(5, (erc20.address, False, TokenType["UnderlyingToken"], 18, 0))
        cToken = MockCToken.deploy(8, {"from": accounts[0]})
        cToken.setUnderlying(erc20)
        cToken.setAnswer(50e18)
        erc20.transfer(tokenHandler, 1e18)

        assetRate = MockCTokenAssetRateAdapter.deploy(cToken.address, {"from": accounts[0]})
        oracle = CompoundV2HoldingsOracle.deploy((tokenHandler.address, erc20.address, cToken.address, assetRate.address), {"from": accounts[0]})
        tokenHandler.initPrimeCashCurve(
            5, 100e8, 0, get_interest_rate_curve(), oracle, True, {"from": accounts[0]}
        )

        erc20.approve(tokenHandler.address, 1000e18, {"from": accounts[0]})

        # This is a deposit
        txn = tokenHandler.depositUnderlyingExternal(accounts[0].address, 5, 1e18, False)

        balanceBefore = erc20.balanceOf(tokenHandler.address)
        assert balanceBefore == 2e18
        assert txn.return_value[0] == 1e18

        # This is a withdraw
        withdrawAmt = 0.5e18
        withdrawPCash = tokenHandler.convertFromUnderlying(
            tokenHandler.buildPrimeRateView(5, chain.time() + 1)[0], -0.5e8
        )
        txn = tokenHandler.withdrawPrimeCash(accounts[0].address, 5, withdrawPCash, False)

        assert erc20.balanceOf(tokenHandler.address) == balanceBefore - withdrawAmt
        assert txn.return_value[0] == -int(withdrawAmt)

    def test_transfer_failures(self, tokens, accounts):
        tokenHandler = tokens["handler"]
        token = tokens["tokens"][1]

        token.approve(tokenHandler, 2 ** 255, {"from": accounts[1]})
        assert token.balanceOf(accounts[1]) == 0

        with brownie.reverts():
            # Reverts when account has no balance
            tokenHandler.depositUnderlyingExternal(accounts[1], 2, 1e18, False)

        with brownie.reverts():
            # Reverts when contract has no balance
            tokenHandler.withdrawPrimeCash(accounts[0], 2, -10_000e8, False)

        with brownie.reverts("ETH Balance"):
            # Reverts when sending insufficient ETH
            tokenHandler.depositUnderlyingExternal(
                accounts[0], 1, 100e18, False, {"from": accounts[0], "value": 0.001e18}
            )

    def transfer_factors(self, tokens, i, accounts):
        tokenHandler = tokens["handler"]
        (primeRate, _) = tokenHandler.buildPrimeRateView(i + 1, chain.time())
        factorsBefore = tokenHandler.getPrimeCashFactors(i + 1)
        t = tokens["tokens"][i]

        return {
            "balance": tokens["oracles"][i].getTotalUnderlyingValueView(),
            "accountBalance": accounts[0].balance() if i == 0 else t.balanceOf(accounts[0]),
            "primeRate": primeRate,
            "factors": factorsBefore,
        }

    def post_transfer_assertions(
        self,
        tokens,
        i,
        accounts,
        accountBalanceAfter,
        beforeFactors,
        primeCashAmount,
        actualTransfer,
        primeRateAfter,
        txn,
    ):
        tokenHandler = tokens["handler"]
        t = tokens["tokens"][i]

        balanceAfter = tokens["oracles"][i].getTotalUnderlyingValueView()
        factorsAfter = tokenHandler.getPrimeCashFactors(i + 1)
        balanceBefore = beforeFactors["balance"]
        factorsBefore = beforeFactors["factors"]

        reserveFee = 0
        for e in txn.events['Transfer']:
            if e['to'] == FEE_RESERVE:
                reserveFee += e['value']

        # netSupply = supplyAfter - supplyBefore
        netSupply = factorsAfter["totalPrimeSupply"] - factorsBefore["totalPrimeSupply"]
        
        assert pytest.approx(netSupply, abs=100) == primeCashAmount + reserveFee
        # TODO: an immediate deposit and withdraw should result in less underlying
        # than before...
        assert (primeCashAmount + reserveFee) <= netSupply

        # Actual transfer equals balance change
        if actualTransfer:
            assert actualTransfer == balanceAfter[0] - balanceBefore[0]
        else:
            # For deposit deprecated asset token we just use this calculation since
            # we don't get an underlying external return value
            actualTransfer = balanceAfter[0] - balanceBefore[0]

        # netSupply = convertFromUnderlying(balance after - balance before) + adj
        decimals = 18 if i == 0 else t.decimals()
        expectedNetSupply = tokenHandler.convertFromUnderlying(
            primeRateAfter, math.floor((actualTransfer * 1e8) / 10 ** decimals)
        ) + reserveFee

        assert pytest.approx(netSupply, abs=100) == expectedNetSupply

        assert factorsAfter["lastTotalUnderlyingValue"] == balanceAfter[1]

    @given(
        primeDebt=strategy("int", min_value=0, max_value=1_000e8),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_QUARTER),
        primeCashToMint=strategy("int", min_value=1e8, max_value=10_000e8),
    )
    def test_deposit_exact_to_mint_pcash(
        self, accounts, tokens, primeDebt, offset, primeCashToMint
    ):
        tokenHandler = tokens["handler"]

        for (i, t) in enumerate(tokens["tokens"]):
            if i > 0 and t.symbol() != "NODEBT":
                # Can use prime debt 1-1 here b/c 0 utilization prior
                tokenHandler.updateTotalPrimeDebt(i + 1, primeDebt, primeDebt)
            chain.mine(1, timedelta=offset)

            beforeFactors = self.transfer_factors(tokens, i, accounts)
            expectedDeposit = tokenHandler.convertToExternalAdjusted(
                i + 1, tokenHandler.convertToUnderlying(beforeFactors["primeRate"], primeCashToMint)
            )
            txn = tokenHandler.depositExactToMintPrimeCash(
                accounts[0],
                i + 1,
                primeCashToMint,
                False,
                {"from": accounts[0], "value": expectedDeposit if i == 0 else 0},
            )
            accountBalanceAfter = accounts[0].balance() if i == 0 else t.balanceOf(accounts[0])
            actualTransfer = txn.events['DepositExact']['actualTransferExternal']
            primeRateAfter = txn.events['DepositExact']['pr']
            assert pytest.approx(actualTransfer, rel=1e-8, abs=5) == expectedDeposit
            assert beforeFactors["accountBalance"] - accountBalanceAfter == actualTransfer

            self.post_transfer_assertions(
                tokens,
                i,
                accounts,
                accountBalanceAfter,
                beforeFactors,
                primeCashToMint,
                actualTransfer,
                primeRateAfter,
                txn,
            )

    @given(
        primeDebt=strategy("int", min_value=0, max_value=1_000e8),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_QUARTER),
        primeCashToWithdraw=strategy("int", min_value=-900e8, max_value=-1e8),
    )
    def test_withdraw_pcash(self, accounts, tokens, primeDebt, offset, primeCashToWithdraw):
        tokenHandler = tokens["handler"]

        for (i, t) in enumerate(tokens["tokens"]):
            if i > 0 and t.symbol() != "NODEBT":
                # Can use prime debt 1-1 here b/c 0 utilization prior
                tokenHandler.updateTotalPrimeDebt(i + 1, primeDebt, primeDebt)
            chain.mine(1, timedelta=offset)

            beforeFactors = self.transfer_factors(tokens, i, accounts)
            if i + 1 == 1:
                nativeBalanceBefore = tokenHandler.balance()
            else:
                nativeBalanceBefore = t.balanceOf(tokenHandler)

            txn = tokenHandler.withdrawPrimeCash(
                accounts[0], i + 1, primeCashToWithdraw, False, {"from": accounts[0]}
            )
            accountBalanceAfter = accounts[0].balance() if i == 0 else t.balanceOf(accounts[0])
            actualTransfer = txn.events['WithdrawPCash']['actualTransferExternal']
            primeRateAfter = txn.events['WithdrawPCash']['pr']
            assert beforeFactors["accountBalance"] - accountBalanceAfter == actualTransfer

            if actualTransfer > nativeBalanceBefore:
                if i + 1 == 1:
                    assert len(txn.events["Transfer"]) == 1
                    # This is for the WETH redemption
                    assert len(txn.events["Withdraw"]) == 1
                else:
                    assert len(txn.events["Transfer"]) > 1

            self.post_transfer_assertions(
                tokens,
                i,
                accounts,
                accountBalanceAfter,
                beforeFactors,
                primeCashToWithdraw,
                actualTransfer,
                primeRateAfter,
                txn,
            )

    def test_set_positive_cash_balance(self, accounts, tokenHandler):
        # Sets a positive cash balance
        tokenHandler.setPositiveCashBalance(accounts[0], 1, 100e8)
        assert tokenHandler.getPositiveCashBalance(accounts[0], 1) == 100e8

        # Sets a zero cash balance
        tokenHandler.setPositiveCashBalance(accounts[0], 1, 0)
        assert tokenHandler.getPositiveCashBalance(accounts[0], 1) == 0

        # Reverts on a negative cash balance
        with brownie.reverts():
            tokenHandler.setPositiveCashBalance(accounts[0], 1, -1e8)

        # Reverts on reading a negative cash balance
        tokenHandler.setBalance(accounts[0], 1, -1e8, 0)

        with brownie.reverts():
            tokenHandler.getPositiveCashBalance(accounts[0], 1)

    @pytest.mark.only
    @given(hasNToken=strategy("bool"), allowPrimeBorrow=strategy("bool"))
    def test_fcash_liquidation_neg_cash(self, accounts, tokens, hasNToken, allowPrimeBorrow):
        tokenHandler = tokens["handler"]

        # During fCash liquidation we allow liquidators to pay off debt
        # (i.e. go from negative cash balance to less negative)

        # Set ETH to active
        active_currencies = currencies_list_to_active_currency_bytes([(1, False, True)])
        # Allow prime borrow should have no effect on this method
        context = (0, HAS_CASH_DEBT, 0, 0, active_currencies, allowPrimeBorrow)

        tokenHandler.setAccountContext(accounts[0], context)
        tokenHandler.setBalance(accounts[0], 1, -100e8, 10e8 if hasNToken else 0)

        with brownie.reverts("Neg Cash"):
            # Cannot put the account further into debt
            tokenHandler.setBalanceStorageForfCashLiquidation(accounts[0], 1, -50e8)

        # Can repay the account's debt
        txn = tokenHandler.setBalanceStorageForfCashLiquidation(accounts[0], 1, 10e8)
        ctx = txn.return_value
        assert ctx["hasDebt"] == HAS_CASH_DEBT
        assert ctx["activeCurrencies"] == HexString(active_currencies, "bytes18")

        # Can repay the account's debt in full
        txn = tokenHandler.setBalanceStorageForfCashLiquidation(
            accounts[0],
            1,
            # these rounding errors are persistent
            91e8,
        )
        ctx = txn.return_value
        assert tokenHandler.getPrimeCashFactors(1)['totalPrimeDebt'] == 0
        assert ctx["hasDebt"] == HAS_CASH_DEBT
        # Very hard to get this to exactly zero because negative prime cash is
        # constantly rebasing
        assert ctx["activeCurrencies"] == HexString(active_currencies, "bytes18")

        chain.undo()
        # Can add cash to positive
        txn = tokenHandler.setBalanceStorageForfCashLiquidation(accounts[0], 1, 110e8)
        ctx = txn.return_value
        assert ctx["hasDebt"] == HAS_CASH_DEBT
        assert ctx["activeCurrencies"] == HexString(active_currencies, "bytes18")

    @given(hasNToken=strategy("bool"), allowPrimeBorrow=strategy("bool"))
    def test_fcash_liquidation_pos_cash(self, accounts, tokens, hasNToken, allowPrimeBorrow):
        tokenHandler = tokens["handler"]

        # During fCash liquidation we allow liquidators to
        # take cash balance from the liquidated account
        # (i.e. go from positive cash balance to positive or zero)

        # Set ETH to active
        active_currencies = currencies_list_to_active_currency_bytes([(1, False, True)])
        # Allow prime borrow should have no effect on this method
        context = (0, "0x00", 0, 0, active_currencies, allowPrimeBorrow)

        tokenHandler.setAccountContext(accounts[0], context)
        tokenHandler.setBalance(accounts[0], 1, 100e8, 10e8 if hasNToken else 0)

        with brownie.reverts("Neg Cash"):
            # Cannot put the account into debt
            tokenHandler.setBalanceStorageForfCashLiquidation(accounts[0], 1, -101e8)

        # Can take positive cash
        txn = tokenHandler.setBalanceStorageForfCashLiquidation(accounts[0], 1, -10e8)
        ctx = txn.return_value
        assert ctx["hasDebt"] == "0x00"
        assert ctx["activeCurrencies"] == HexString(active_currencies, "bytes18")

        # Can take cash down to zero
        txn = tokenHandler.setBalanceStorageForfCashLiquidation(accounts[0], 1, -90e8)
        ctx = txn.return_value
        assert ctx["hasDebt"] == "0x00"
        if hasNToken:
            assert ctx["activeCurrencies"] == HexString(active_currencies, "bytes18")
        else:
            assert ctx["activeCurrencies"] == HexString(0, "bytes18")

    @given(
        primeDebt=strategy("int", min_value=0, max_value=1_000e8),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_QUARTER),
        assetCashToDeposit=strategy("int", min_value=1e8, max_value=10_000e8),
    )
    def test_deposit_deprecated_asset_token(
        self, accounts, tokens, primeDebt, offset, assetCashToDeposit
    ):
        tokenHandler = tokens["handler"]
        for (i, t) in enumerate(tokens["tokens"]):
            accountBalanceBefore = tokens["cTokens"][i].approve(
                tokenHandler, 2 ** 255, {"from": accounts[0]}
            )
            accountBalanceBefore = tokens["cTokens"][i].balanceOf(accounts[0])

            if i == 0:
                tokenHandler.setAssetToken(
                    i + 1, (tokens["cTokens"][i], False, TokenType["cETH"], 8, 0)
                )
            elif i == 3:
                # Set this as non-mintable to test
                tokenHandler.setAssetToken(i + 1, (t, False, TokenType["NonMintable"], 8, 0))
            else:
                tokenHandler.setAssetToken(
                    i + 1, (tokens["cTokens"][i], False, TokenType["cToken"], 8, 0)
                )

            if i > 0 and t.symbol() == "NODEBT":
                accountBalanceBefore = t.balanceOf(accounts[0])
                # Scale this up because it is not a cToken
                assetCashToDeposit = assetCashToDeposit * 1e10
            else:
                # Can use prime debt 1-1 here b/c 0 utilization prior
                tokenHandler.updateTotalPrimeDebt(i + 1, primeDebt, primeDebt)
            chain.mine(1, timedelta=offset)

            beforeFactors = self.transfer_factors(tokens, i, accounts)
            beforeFactors["accountBalance"] = accountBalanceBefore
            txn = tokenHandler.depositDeprecatedAssetToken(
                accounts[0], i + 1, assetCashToDeposit, {"from": accounts[0]}
            )
            balanceState = txn.events['DepositUnderlying']['balanceState']
            primeCashDeposited = txn.events['DepositUnderlying']['primeCashDeposited']
            assert balanceState["netCashChange"] == primeCashDeposited

            (primeRateAfter, _) = tokenHandler.buildPrimeRateView(i + 1, txn.timestamp)
            if i > 0 and t.symbol() == "NODEBT":
                accountBalanceAfter = t.balanceOf(accounts[0])
                actualTransferUnderlying = accountBalanceBefore - accountBalanceAfter
            else:
                accountBalanceAfter = tokens["cTokens"][i].balanceOf(accounts[0])
                actualTransferUnderlying = None
            assert accountBalanceBefore - accountBalanceAfter == assetCashToDeposit

            self.post_transfer_assertions(
                tokens,
                i,
                accounts,
                accountBalanceAfter,
                beforeFactors,
                primeCashDeposited,
                actualTransferUnderlying,
                primeRateAfter,
                txn,
            )

    @given(
        primeDebt=strategy("int", min_value=0, max_value=1_000e8),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_QUARTER),
        _underlyingToDeposit=strategy("int", min_value=1, max_value=1000),
    )
    def test_deposit_underlying_token(
        self, accounts, tokens, primeDebt, offset, _underlyingToDeposit
    ):
        tokenHandler = tokens["handler"]

        for (i, t) in enumerate(tokens["tokens"]):
            if i > 0 and t.symbol() != "NODEBT":
                # Can use prime debt 1-1 here b/c 0 utilization prior
                tokenHandler.updateTotalPrimeDebt(i + 1, primeDebt, primeDebt)
            chain.mine(1, timedelta=offset)
            decimals = 18 if i == 0 else t.decimals()
            underlyingToDeposit = _underlyingToDeposit * 10 ** decimals

            beforeFactors = self.transfer_factors(tokens, i, accounts)
            txn = tokenHandler.depositUnderlyingToken(
                accounts[0],
                i + 1,
                underlyingToDeposit,
                False,
                {"from": accounts[0], "value": underlyingToDeposit if i == 0 else 0},
            )
            accountBalanceAfter = accounts[0].balance() if i == 0 else t.balanceOf(accounts[0])
            balanceState = txn.events['DepositUnderlying']['balanceState']
            primeCashDeposited = txn.events['DepositUnderlying']['primeCashDeposited']
            (primeRateAfter, _) = tokenHandler.buildPrimeRateView(i + 1, txn.timestamp)

            assert beforeFactors["accountBalance"] - accountBalanceAfter == underlyingToDeposit
            actualTransfer = beforeFactors["accountBalance"] - accountBalanceAfter
            assert balanceState["netCashChange"] == primeCashDeposited

            self.post_transfer_assertions(
                tokens,
                i,
                accounts,
                accountBalanceAfter,
                beforeFactors,
                primeCashDeposited,
                actualTransfer,
                primeRateAfter,
                txn,
            )

    def test_return_excess_eth_in_deposit_exact(self, accounts, tokens, weth):
        tokenHandler = tokens["handler"]

        ethBalanceBefore = accounts[0].balance()
        txn = tokenHandler.depositExactToMintPrimeCash(
            accounts[0], 1, 100e8, False, {"from": accounts[0], "value": 200e18}
        )
        ethBalanceAfter = accounts[0].balance()
        # Excess ETH returned
        assert ethBalanceBefore - ethBalanceAfter == txn.return_value["actualTransferExternal"]

        wethBalanceBefore = weth.balanceOf(accounts[0])
        txn = tokenHandler.depositExactToMintPrimeCash(
            accounts[0], 1, 100e8, True, {"from": accounts[0], "value": 200e18}
        )
        wethBalanceAfter = weth.balanceOf(accounts[0])
        # Excess ETH returned as WETH
        assert (
            wethBalanceAfter - wethBalanceBefore
            == 200e18 - txn.return_value["actualTransferExternal"]
        )

    def test_return_excess_eth_in_deposit_underlying(self, accounts, tokens, weth):
        tokenHandler = tokens["handler"]

        ethBalanceBefore = accounts[0].balance()
        txn = tokenHandler.depositUnderlyingExternal(
            accounts[0], 1, 100e18, False, {"from": accounts[0], "value": 200e18}
        )
        ethBalanceAfter = accounts[0].balance()
        # Excess ETH returned
        actualTransferExternal = txn.return_value["actualTransferExternal"]
        assert ethBalanceBefore - ethBalanceAfter == actualTransferExternal

        ethBalanceBefore = accounts[0].balance()
        txn = tokenHandler.depositUnderlyingToken(
            accounts[0], 1, 100e18, False, {"from": accounts[0], "value": 200e18}
        )
        ethBalanceAfter = accounts[0].balance()
        # Excess ETH returned
        assert ethBalanceBefore - ethBalanceAfter == actualTransferExternal

        wethBalanceBefore = weth.balanceOf(accounts[0])
        txn = tokenHandler.depositUnderlyingExternal(
            accounts[0], 1, 100e18, True, {"from": accounts[0], "value": 200e18}
        )
        wethBalanceAfter = weth.balanceOf(accounts[0])
        # Excess ETH returned as WETH
        actualTransferExternal = txn.return_value["actualTransferExternal"]
        assert wethBalanceAfter - wethBalanceBefore == 200e18 - actualTransferExternal

        wethBalanceBefore = weth.balanceOf(accounts[0])
        txn = tokenHandler.depositUnderlyingToken(
            accounts[0], 1, 100e18, True, {"from": accounts[0], "value": 200e18}
        )
        wethBalanceAfter = weth.balanceOf(accounts[0])
        # Excess ETH returned as WETH
        assert wethBalanceAfter - wethBalanceBefore == 200e18 - actualTransferExternal

    def test_withdraw_wrapped_prime_cash(self, accounts, tokens, weth):
        tokenHandler = tokens["handler"]
        ethBalanceBefore = accounts[0].balance()
        wethBalanceBefore = weth.balanceOf(accounts[0])

        tokenHandler.withdrawPrimeCash(accounts[0], 1, -1e8, True, {"from": accounts[0]})

        ethBalanceAfter = accounts[0].balance()
        wethBalanceAfter = weth.balanceOf(accounts[0])

        assert ethBalanceBefore == ethBalanceAfter
        assert wethBalanceAfter - wethBalanceBefore == 1e18

    def test_withdraw_wrapped_finalize(self, accounts, tokens, weth):
        tokenHandler = tokens["handler"]
        ethBalanceBefore = accounts[0]
        wethBalanceBefore = weth.balanceOf(accounts[0])

        (primeRate, _) = tokenHandler.buildPrimeRateView(1, chain.time())

        balanceState = get_balance_state(
            currencyId=1, storedCashBalance=1e8, primeCashWithdraw=-1e8, primeRate=primeRate
        )
        tokenHandler.finalize(balanceState, accounts[0], True, {"from": accounts[0]})

        ethBalanceAfter = accounts[0]
        wethBalanceAfter = weth.balanceOf(accounts[0])

        assert ethBalanceBefore == ethBalanceAfter
        assert wethBalanceAfter - wethBalanceBefore == 1e18

    def test_deposit_methods_revert_on_negative_inputs(self, accounts, tokens):
        tokenHandler = tokens["handler"]
        with brownie.reverts():
            tokenHandler.depositUnderlyingToken(accounts[0], 1, -1e18, False, {"from": accounts[0]})

        with brownie.reverts():
            tokenHandler.depositDeprecatedAssetToken(accounts[0], 1, -1e8, {"from": accounts[0]})

        with brownie.reverts():
            tokenHandler.depositExactToMintPrimeCash(
                accounts[0], 1, -1e8, False, {"from": accounts[0]}
            )

    def test_finalize_cannot_withdraw_to_negative_ntoken(self, tokens, accounts):
        tokenHandler = tokens["handler"]
        (primeRate, _) = tokenHandler.buildPrimeRateView(1, chain.time())
        balanceState = get_balance_state(
            currencyId=1,
            storedNTokenBalance=100e8,
            netNTokenSupplyChange=-150e8,
            netNTokenTransfer=0,
            primeRate=primeRate,
        )

        with brownie.reverts():
            tokenHandler.finalize(balanceState, accounts[0], False)

        balanceState = get_balance_state(
            currencyId=1,
            storedNTokenBalance=100e8,
            netNTokenSupplyChange=0,
            netNTokenTransfer=-150e8,
            primeRate=primeRate,
        )
        with brownie.reverts("Neg nToken"):
            tokenHandler.finalize(balanceState, accounts[0], False)

    def test_finalize_ntoken_sets_incentives(self, tokens, accounts):
        tokenHandler = tokens["handler"]
        (_, noteToken) = deployNoteERC20(accounts[0])
        noteToken.initialize([tokenHandler], [100_000_000e8], accounts[0], {"from": accounts[0]})
        tokenHandler.setIncentives(1, accounts[9])
        (primeRate, _) = tokenHandler.buildPrimeRateView(1, chain.time())

        balanceState = get_balance_state(
            currencyId=1,
            storedNTokenBalance=0,
            netNTokenSupplyChange=100e8,
            netNTokenTransfer=0,
            primeRate=primeRate,
        )

        txn = tokenHandler.finalize(balanceState, accounts[0], False)
        (ctx, transferAmountExternal) = txn.return_value
        active_currencies = currencies_list_to_active_currency_bytes([(1, False, True)])
        assert transferAmountExternal == 0
        assert ctx["hasDebt"] == "0x00"
        assert ctx["activeCurrencies"] == HexString(active_currencies, "bytes18")

        (bs, _) = tokenHandler.loadBalanceState(accounts[0], 1)
        assert bs["storedNTokenBalance"] == 100e8

        chain.mine(1, timedelta=SECONDS_IN_QUARTER)
        balanceState = get_balance_state(
            currencyId=1,
            storedNTokenBalance=100e8,
            netNTokenSupplyChange=100e8,
            netNTokenTransfer=0,
            primeRate=primeRate,
        )
        txn = tokenHandler.finalize(balanceState, accounts[0], False)
        (bs, _) = tokenHandler.loadBalanceState(accounts[0], 1)
        assert bs["accountIncentiveDebt"] > 0
        assert bs["storedNTokenBalance"] == 200e8

    @given(
        primeDebt=strategy("int", min_value=0, max_value=1_000e8),
        offset=strategy("int", min_value=3600, max_value=SECONDS_IN_QUARTER),
        netCashChange=strategy("int", min_value=-100_000e8, max_value=100_000e8),
        primeCashWithdraw=strategy("int", min_value=-950e8, max_value=0),
        allowPrimeBorrow=strategy("bool"),
    )
    def test_set_negative_cash_balance(
        self,
        tokens,
        accounts,
        primeDebt,
        offset,
        netCashChange,
        primeCashWithdraw,
        allowPrimeBorrow,
    ):
        tokenHandler = tokens["handler"]

        if allowPrimeBorrow:
            tokenHandler.enablePrimeBorrow(accounts[0])


        for (i, t) in enumerate(tokens["tokens"]):
            allowsDebt = False
            if i > 0 and t.symbol() != "NODEBT":
                # Can use prime debt 1-1 here b/c 0 utilization prior
                tokenHandler.updateTotalPrimeDebt(i + 1, primeDebt, primeDebt)
                allowsDebt = True
            elif i == 0:
                allowsDebt = True

            chain.mine(1, timedelta=offset)

            (primeRate, _) = tokenHandler.buildPrimeRateView(i + 1, chain.time())

            balanceState = get_balance_state(
                currencyId=i + 1,
                storedCashBalance=0,
                netCashChange=netCashChange,
                primeCashWithdraw=primeCashWithdraw,
                primeRate=primeRate,
            )
            finalCash = netCashChange + primeCashWithdraw

            if finalCash < 0 and (not allowPrimeBorrow or not allowsDebt):
                # Check that it reverts when borrowing and the account has not authorized
                # prime borrow or the currency does not allow debt
                with brownie.reverts():
                    tokenHandler.finalize(balanceState, accounts[0], False)
                
                return
            else:
                txn = tokenHandler.finalize(balanceState, accounts[0], False)
                transferAmountExternal = txn.events['Finalize']['transferAmountExternal']
                primeRate = txn.events['Finalize']['primeRate']
                (bs, ctx) = tokenHandler.loadBalanceState(accounts[0], i + 1)

                # Rounding error here on small dust withdraws
                assert pytest.approx(bs["storedCashBalance"], abs=1) == finalCash
                
                decimals = 18 if i == 0 else t.decimals()
                adjustment = 1e10 if decimals == 18 else 1
                assert pytest.approx(transferAmountExternal, abs=adjustment) == tokenHandler.convertToExternal(
                    i + 1, tokenHandler.convertToUnderlying(primeRate, primeCashWithdraw)
                )

            if finalCash < 0:
                assert ctx["hasDebt"] == HAS_CASH_DEBT
            else:
                assert ctx["hasDebt"] == "0x00"

            chain.mine(1, timedelta=offset)

            # check that debt balance has accrued over time
            (bs, ctx) = tokenHandler.loadBalanceState(accounts[0], i + 1)

            # Dust balances may not accrue debt
            if bs["storedCashBalance"] < -1e6:
                assert bs["storedCashBalance"] < finalCash
