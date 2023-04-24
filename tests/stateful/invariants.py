import math
from collections import defaultdict

import pytest
from brownie import MockERC20
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from tests.constants import (
    HAS_ASSET_DEBT,
    HAS_BOTH_DEBT,
    HAS_CASH_DEBT,
    PRIME_CASH_VAULT_MATURITY,
    SECONDS_IN_QUARTER,
    ZERO_ADDRESS
)
from tests.helpers import active_currencies_to_list, get_settlement_date

chain = Chain()
QUARTER = 86400 * 90


def get_all_markets(env, currencyId):
    block_time = chain.time()
    current_time_ref = env.startTime - (env.startTime % QUARTER)
    markets = []
    while current_time_ref < block_time:
        markets.append(env.notional.getActiveMarketsAtBlockTime(currencyId, current_time_ref))
        current_time_ref = current_time_ref + QUARTER

    return markets


def check_system_invariants(env, accounts, vaults=[], vaultfCashOverrides=[]):
    for (currencyId, nToken) in env.nToken.items():
        try:
            env.notional.initializeMarkets(currencyId, False)
        except Exception as e:
            print(e)

    settle_all_accounts(env, accounts)
    check_stored_token_balance(env)
    check_cash_balance(env, accounts, vaults)
    check_ntoken(env, accounts)
    check_portfolio_invariants(env, accounts, vaults, vaultfCashOverrides)
    check_account_context(env, accounts)
    check_token_incentive_balance(env, accounts)
    check_vault_invariants(env, accounts, vaults)


def settle_all_accounts(env, accounts):
    for account in accounts:
        try:
            env.notional.settleAccount(account)
        except:
            pass

def check_stored_token_balance(env):
    for (_, currencyId) in env.currencyId.items():
        (assetToken, underlyingToken) = env.notional.getCurrency(currencyId)
        if underlyingToken['tokenAddress'] == ZERO_ADDRESS:
            assert env.notional.getStoredTokenBalances([ZERO_ADDRESS])[0] == env.notional.balance()
        else:
            erc20 = MockERC20.at(underlyingToken['tokenAddress'])
            assert env.notional.getStoredTokenBalances([underlyingToken['tokenAddress']])[0] == erc20.balanceOf(env.notional)

        if assetToken['tokenAddress'] != ZERO_ADDRESS:
            erc20 = MockERC20.at(assetToken['tokenAddress'])
            assert env.notional.getStoredTokenBalances([assetToken['tokenAddress']])[0] == erc20.balanceOf(env.notional)

def check_cash_balance(env, accounts, vaults):
    # For every currency, check that the contract balance matches the account
    # balances and capital deposited trackers
    for (_, currencyId) in env.currencyId.items():
        positiveCashBalances = 0
        negativeCashBalances = 0
        nTokenTotalBalances = 0
        # This needs to accrue interest in order for the balance to be correct if there are fees.
        chain.mine(1, timedelta=1)
        env.notional.accruePrimeInterest(currencyId)
        chain.mine(1, timedelta=2)
        (primeRate, primeFactors, _, _) = env.notional.getPrimeFactors(currencyId, chain.time())

        for account in accounts:
            (cashBalance, nTokenBalance, _) = env.notional.getAccountBalance(
                currencyId, account.address
            )
            if cashBalance > 0:
                positiveCashBalances += cashBalance
            else:
                negativeCashBalances += cashBalance
            nTokenTotalBalances += nTokenBalance

        for vault in vaults:
            config = env.notional.getVaultConfig(vault)
            if currencyId not in (
                [config["borrowCurrencyId"]] + list(config["secondaryBorrowCurrencies"])
            ):
                break

            maxMarkets = config["maxBorrowMarketIndex"]
            markets = env.notional.getActiveMarkets(currencyId)
            maturities = [
                markets[0][1] - SECONDS_IN_QUARTER,  # Prev maturity
                PRIME_CASH_VAULT_MATURITY,
            ] + [markets[i][1] for i in range(0, maxMarkets)]

            for m in maturities:
                totalDebtUnderlying = 0
                if currencyId == config["borrowCurrencyId"]:
                    state = env.notional.getVaultState(vault, m)
                    totalDebtUnderlying = state["totalDebtUnderlying"]
                else:
                    totalDebtUnderlying = env.notional.getSecondaryBorrow(
                        vault, currencyId, m
                    )

                if m <= chain.time() or m == PRIME_CASH_VAULT_MATURITY:
                    # Matured fCash balances are returned as prime cash underlying
                    negativeCashBalances += math.floor(
                        totalDebtUnderlying * 1e36 / primeRate["supplyFactor"]
                    )

            for a in accounts:
                # If a vault account is liquidated, it holds cash in its temp cash balance
                vaultAccount = env.notional.getVaultAccount(a, vault)
                if currencyId == config['borrowCurrencyId']:
                    positiveCashBalances += vaultAccount["tempCashBalance"]
                elif currencyId == config['secondaryBorrowCurrencies'][0]:
                    positiveCashBalances += env.notional.getVaultAccountSecondaryDebt(a, vault)['accountSecondaryCashHeld'][0]
                elif currencyId == config['secondaryBorrowCurrencies'][1]:
                    positiveCashBalances += env.notional.getVaultAccountSecondaryDebt(a, vault)['accountSecondaryCashHeld'][1]

        # Add nToken balances
        positiveCashBalances += env.notional.getNTokenAccount(env.nToken[currencyId].address)[
            "cashBalance"
        ]

        # Loop markets to check for cashBalances
        markets = env.notional.getActiveMarkets(currencyId)
        for m in markets:
            positiveCashBalances += m[3]

        positiveCashBalances += env.notional.getReserveBalance(currencyId)

        # Check prime factors
        calculatedSupplyDebt = math.floor(
            Wei(primeFactors["totalPrimeDebt"])
            * Wei(primeRate["debtFactor"])
            / Wei(primeRate["supplyFactor"])
        )
        # TODO: it appears that this does not converge for a short period of time after a large
        # borrow...must investigate
        assert pytest.approx(calculatedSupplyDebt, rel=1e-8, abs=10_000) == -negativeCashBalances

        assert pytest.approx(primeFactors["totalPrimeSupply"], rel=5e-10, abs=10_000) == positiveCashBalances
        # Subtract one here to prevent some flaky test things
        assert primeFactors["totalPrimeSupply"] >= positiveCashBalances - 100

        # primeDiff must equal lastTotalUnderlyingValue
        primeDiff = Wei(primeFactors["totalPrimeSupply"]) * Wei(primeRate["supplyFactor"]) / Wei(
            1e36
        ) - Wei(primeFactors["totalPrimeDebt"]) * Wei(primeRate["debtFactor"]) / Wei(1e36)
        assert pytest.approx(primeFactors["lastTotalUnderlyingValue"] / primeDiff, abs=1e-3) == 1
        assert primeFactors["lastTotalUnderlyingValue"] + 1 >= primeDiff

        # Check that total supply equals total balances
        assert nTokenTotalBalances == env.nToken[currencyId].totalSupply()


def check_ntoken(env, accounts):
    # For every nToken, check that it has no other balances and its
    # total outstanding supply matches its supply
    for (currencyId, nToken) in env.nToken.items():
        totalSupply = nToken.totalSupply()
        totalTokensHeld = 0

        for account in accounts:
            (_, tokens, _) = env.notional.getAccountBalance(currencyId, account.address)
            totalTokensHeld += tokens

        # Ensure that total supply equals tokens held
        assert totalTokensHeld == totalSupply

        # Ensure that the nToken never holds other balances
        for (_, testCurrencyId) in env.currencyId.items():
            (cashBalance, tokens, lastMintTime) = env.notional.getAccountBalance(
                testCurrencyId, nToken.address
            )
            assert tokens == 0
            assert lastMintTime == 0

            if testCurrencyId != currencyId:
                assert cashBalance == 0

        # Ensure that the nToken holds enough PV for negative fcash balances
        nTokenAccount = env.notional.getNTokenAccount(nToken.address).dict()
        if nTokenAccount["cashBalance"] < 0:
            assert nToken.getPresentValueAssetDenominated() + nTokenAccount["cashBalance"] > 0


def check_portfolio_invariants(env, accounts, vaults, vaultfCashOverrides=[]):
    fCashDebt = defaultdict(lambda: 0)
    fCashLend = defaultdict(lambda: 0)
    liquidityToken = defaultdict(dict)
    for o in vaultfCashOverrides:
        if o["fCash"] > 0:
            fCashLend[(o["currencyId"], o["maturity"])] += o["fCash"]
        else:
            fCashDebt[(o["currencyId"], o["maturity"])] += o["fCash"]

    for account in accounts:
        portfolio = env.notional.getAccountPortfolio(account.address)
        for asset in portfolio:
            if asset[2] == 1:
                if asset[3] > 0:
                    fCashLend[(asset[0], asset[1])] += asset[3]
                else:
                    fCashDebt[(asset[0], asset[1])] += asset[3]
            else:
                if (asset[0], asset[1], asset[2]) in liquidityToken:
                    # Is liquidity token, liquidityToken[currencyId][maturity][assetType]
                    # Each liquidity token is indexed by its type and settlement date
                    liquidityToken[(asset[0], asset[1], asset[2])] += asset[3]
                else:
                    liquidityToken[(asset[0], asset[1], asset[2])] = asset[3]

    # Check nToken portfolios
    for (currencyId, nToken) in env.nToken.items():
        (portfolio, ifCashAssets) = env.notional.getNTokenPortfolio(nToken.address)

        for asset in portfolio:
            # nToken cannot have any other currencies or fCash in its portfolio
            assert asset[0] == currencyId
            assert asset[2] != 1
            if (asset[0], asset[1], asset[2]) in liquidityToken:
                # Is liquidity token, liquidityToken[currencyId][maturity][assetType]
                # Each liquidity token is indexed by its type and settlement date
                liquidityToken[(asset[0], asset[1], asset[2])] += asset[3]
            else:
                liquidityToken[(asset[0], asset[1], asset[2])] = asset[3]

        for asset in ifCashAssets:
            assert asset[0] == currencyId
            if asset[3] > 0:
                fCashLend[(asset[0], asset[1])] += asset[3]
            else:
                fCashDebt[(asset[0], asset[1])] += asset[3]

    # Check fCash in markets
    for (_, currencyId) in env.currencyId.items():
        markets = get_all_markets(env, currencyId)
        for marketGroup in markets:
            for (i, m) in enumerate(marketGroup):
                # Add total fCash in market
                assert m[2] >= 0
                fCashLend[(currencyId, m[1])] += m[2]

                # Assert that total liquidity equals the tokens in portfolios
                if m[4] > 0:
                    assert liquidityToken[(currencyId, m[1], 2 + i)] == m[4]
                elif m[4] == 0:
                    assert (currencyId, m[1], 2 + i) not in liquidityToken
                else:
                    # Should never be zero
                    assert False

    # Check fCash in vaults
    for vault in vaults:
        config = env.notional.getVaultConfig(vault)
        allCurrencies = [
            c
            for c in ([config["borrowCurrencyId"]] + list(config["secondaryBorrowCurrencies"]))
            if c != 0
        ]
        maxMarkets = config["maxBorrowMarketIndex"]
        markets = env.notional.getActiveMarkets(config["borrowCurrencyId"])
        maturities = [markets[i][1] for i in range(0, maxMarkets)]

        for m in maturities:
            for currencyId in allCurrencies:
                totalDebtUnderlying = 0
                if currencyId == config["borrowCurrencyId"]:
                    state = env.notional.getVaultState(vault, m)
                    totalDebtUnderlying = state["totalDebtUnderlying"]
                else:
                    totalDebtUnderlying = env.notional.getSecondaryBorrow(vault, currencyId, m)

                fCashDebt[(currencyId, m)] += totalDebtUnderlying

    for (key, debt) in fCashDebt.items():
        # Assert that all fCash balances net off to zero
        assert fCashLend[key] + debt == 0
        # Check that the total fCash debt equals total debt outstanding
        overrides = sum([v['fCash'] for v in vaultfCashOverrides if v['currencyId'] == key[0] and v['maturity'] == key[1]])
        assert env.notional.getTotalfCashDebtOutstanding(key[0], key[1]) + overrides == debt

    # Check the opposite way just in case
    for (key, lend) in fCashLend.items():
        # Assert that all fCash balances net off to zero
        assert fCashDebt[key] + lend == 0


def check_account_context(env, accounts):
    for account in accounts:
        context = env.notional.getAccountContext(account.address)
        activeCurrencies = list(active_currencies_to_list(context["activeCurrencies"]))

        hasCashDebt = False
        for (_, currencyId) in env.currencyId.items():
            # Checks that active currencies is set properly
            (cashBalance, nTokenBalance, _) = env.notional.getAccountBalance(
                currencyId, account.address
            )
            if (cashBalance != 0 or nTokenBalance != 0) and context[3] != currencyId:
                assert (currencyId, True) in [(a[0], a[2]) for a in activeCurrencies]

            if cashBalance < 0:
                hasCashDebt = True

        portfolio = env.notional.getAccountPortfolio(account.address)
        nextSettleTime = 0
        if len(portfolio) > 0:
            nextSettleTime = get_settlement_date(portfolio[0], chain.time())

        hasPortfolioDebt = False
        for asset in portfolio:
            if context[3] == 0:
                # Check that currency id is in the active currencies list
                assert (asset[0], True) in [(a[0], a[1]) for a in activeCurrencies]
            else:
                # Check that assets are set in the bitmap
                assert asset[0] == context[3]

            settleTime = get_settlement_date(asset, chain.time())

            if settleTime < nextSettleTime:
                # Set to the lowest maturity
                nextSettleTime = settleTime

            if asset[3] < 0:
                # Negative fcash
                hasPortfolioDebt = True

        # Check next settle time for portfolio array
        if context[3] == 0:
            assert context[0] == nextSettleTime

        # Check that has debt is set properly.
        if hasPortfolioDebt and hasCashDebt:
            assert context[1] == HAS_BOTH_DEBT
        elif hasPortfolioDebt:
            # It's possible that cash debt is set to true  but out of sync due to not running
            # a free collateral check after settling cash debts
            assert context[1] == HAS_BOTH_DEBT or context[1] == HAS_ASSET_DEBT
        elif hasCashDebt:
            assert context[1] == HAS_CASH_DEBT


def check_token_incentive_balance(env, accounts):
    totalTokenBalance = 0

    for account in accounts:
        totalTokenBalance += env.noteERC20.balanceOf(account)

    totalTokenBalance += env.noteERC20.balanceOf(env.notional.address)

    if hasattr(env, "governor"):
        totalTokenBalance += env.noteERC20.balanceOf(env.governor.address)
        totalTokenBalance += env.noteERC20.balanceOf(env.multisig.address)

    assert totalTokenBalance == 100000000e8


def check_vault_invariants(env, accounts, vaults):
    for vault in vaults:
        config = env.notional.getVaultConfig(vault)
        primaryCurrency = config["borrowCurrencyId"]
        maxMarkets = config["maxBorrowMarketIndex"]

        totalDebtPerMaturity = defaultdict(lambda: 0)
        totalVaultSharesPerMaturity = defaultdict(lambda: 0)
        totalfCashInVault = 0
        totalSecondaryDebtPerMaturity = {}
        if config["secondaryBorrowCurrencies"][0] != 0:
            totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][0]] = defaultdict(
                lambda: 0
            )

        if config["secondaryBorrowCurrencies"][1] != 0:
            totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][1]] = defaultdict(
                lambda: 0
            )

        totalSecondaryfCashDebt = dict(
            {(c, 0) for c in config["secondaryBorrowCurrencies"] if c != 0}
        )

        maturities = [ m[1] for m in env.notional.getActiveMarkets(primaryCurrency) ] + [ PRIME_CASH_VAULT_MATURITY ]

        for account in accounts[0:4]:
            va = env.notional.getVaultAccount(account, vault)
            if va["maturity"] != 0 and va["maturity"] < chain.time():
                env.notional.settleVaultAccount(account, vault)

            vaultAccount = env.notional.getVaultAccount(account, vault)
            if vaultAccount["maturity"] != 0:
                totalDebtPerMaturity[vaultAccount["maturity"]] += vaultAccount[
                    "accountDebtUnderlying"
                ]
                totalVaultSharesPerMaturity[vaultAccount["maturity"]] += vaultAccount["vaultShares"]

            secondaryDebt = env.notional.getVaultAccountSecondaryDebt(account, vault)
            assert (
                secondaryDebt["maturity"] == 0
                or secondaryDebt["maturity"] == vaultAccount["maturity"]
            )
            if secondaryDebt["accountSecondaryDebt"][0] != 0:
                totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][0]][
                    secondaryDebt["maturity"]
                ] += secondaryDebt["accountSecondaryDebt"][0]

            if secondaryDebt["accountSecondaryDebt"][1] != 0:
                totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][1]][
                    secondaryDebt["maturity"]
                ] += secondaryDebt["accountSecondaryDebt"][1]

        for (i, maturity) in enumerate(maturities):
            state = env.notional.getVaultState(vault, maturity)
            if i + 1 > maxMarkets and maturity != PRIME_CASH_VAULT_MATURITY:
                # Cannot have state past max markets
                assert state["totalDebtUnderlying"] == 0
                assert state["totalVaultShares"] == 0
                assert not state["isSettled"]
            else:
                if maturity == PRIME_CASH_VAULT_MATURITY:
                    assert pytest.approx(state["totalDebtUnderlying"], abs=1e6) == totalDebtPerMaturity[maturity]
                else:
                    assert state["totalDebtUnderlying"] == totalDebtPerMaturity[maturity]
                    totalfCashInVault += state["totalDebtUnderlying"]

                assert state["totalVaultShares"] == totalVaultSharesPerMaturity[maturity]

                if config["secondaryBorrowCurrencies"][0] != 0:
                    totalDebt = env.notional.getSecondaryBorrow(
                        vault, config["secondaryBorrowCurrencies"][0], maturity
                    )
                    totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][0]][
                        maturity
                    ] == totalDebt

                    if maturity != PRIME_CASH_VAULT_MATURITY:
                        totalSecondaryfCashDebt[config["secondaryBorrowCurrencies"][0]] += totalDebt

                if config["secondaryBorrowCurrencies"][1] != 0:
                    totalDebt = env.notional.getSecondaryBorrow(
                        vault, config["secondaryBorrowCurrencies"][1], maturity
                    )
                    totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][1]][
                        maturity
                    ] == totalDebt

                    if maturity != PRIME_CASH_VAULT_MATURITY:
                        totalSecondaryfCashDebt[config["secondaryBorrowCurrencies"][1]] += totalDebt

        (currentPrimeDebt, totalfCashUsed, _) = env.notional.getBorrowCapacity(
            vault, primaryCurrency
        )
        assert totalfCashInVault == -totalfCashUsed
        # Allow a little drift because these are both in underlying terms
        assert (pytest.approx(currentPrimeDebt, abs=1e6) == -totalDebtPerMaturity[PRIME_CASH_VAULT_MATURITY])

        if config["secondaryBorrowCurrencies"][0] != 0:
            (currentPrimeDebt, totalfCashUsed, _) = env.notional.getBorrowCapacity(
                vault, config["secondaryBorrowCurrencies"][0]
            )
            assert totalSecondaryfCashDebt[config["secondaryBorrowCurrencies"][0]] == -totalfCashUsed
            assert pytest.approx(-currentPrimeDebt, abs=150) == totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][0]][PRIME_CASH_VAULT_MATURITY ]

        if config["secondaryBorrowCurrencies"][1] != 0:
            (currentPrimeDebt, totalfCashUsed, _) = env.notional.getBorrowCapacity(
                vault, config["secondaryBorrowCurrencies"][1]
            )
            assert totalSecondaryfCashDebt[config["secondaryBorrowCurrencies"][1]] == -totalfCashUsed
            assert pytest.approx(-currentPrimeDebt, abs=1) == totalSecondaryDebtPerMaturity[config["secondaryBorrowCurrencies"][1]][PRIME_CASH_VAULT_MATURITY ]
