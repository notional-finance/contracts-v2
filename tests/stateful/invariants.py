from collections import defaultdict

from brownie.network.state import Chain
from tests.storage.test_account_context import bytes_to_list

chain = Chain()
QUARTER = 86400 * 90


def get_all_markets(env, currencyId):
    block_time = chain.time()
    current_time_ref = env.startTime - (env.startTime % QUARTER)
    markets = []
    while current_time_ref < block_time:
        markets.append(
            env.router["Views"].getActiveMarketsAtBlockTime(currencyId, current_time_ref)
        )
        current_time_ref = current_time_ref + QUARTER

    return markets


def check_system_invariants(env, accounts):
    check_cash_balance(env, accounts)
    check_perp_token(env, accounts)
    check_portfolio_invariants(env, accounts)
    check_account_context(env, accounts)


def check_cash_balance(env, accounts):
    # For every currency, check that the contract balance matches the account
    # balances and capital deposited trackers
    for (symbol, currencyId) in env.currencyId.items():
        tokenBalance = env.token[symbol].balanceOf(env.router["Views"].address)
        # Notional contract should never accumulate underlying balances
        assert tokenBalance == 0

        contractBalance = env.cToken[symbol].balanceOf(env.router["Views"].address)
        accountBalances = 0
        perpTokenTotalBalances = 0

        for account in accounts:
            (cashBalance, perpTokenBalance, lastMintTime) = env.router["Views"].getAccountBalance(
                currencyId, account.address
            )
            accountBalances += cashBalance
            perpTokenTotalBalances += perpTokenBalance

        # Add perp token balances
        (cashBalance, _, _) = env.router["Views"].getAccountBalance(
            currencyId, env.perpToken[currencyId].address
        )
        accountBalances += cashBalance

        # Loop markets to check for cashBalances
        markets = get_all_markets(env, currencyId)
        for marketGroup in markets:
            accountBalances += sum([m[3] for (i, m) in enumerate(marketGroup)])

        assert contractBalance == accountBalances
        # Check that total supply equals total balances
        assert perpTokenTotalBalances == env.perpToken[currencyId].totalSupply()


def check_perp_token(env, accounts):
    # For every perp token, check that it has no other balances and its
    # total outstanding supply matches its supply
    for (currencyId, perpToken) in env.perpToken.items():
        totalSupply = perpToken.totalSupply()
        totalTokensHeld = 0

        for account in accounts:
            (_, tokens, _) = env.router["Views"].getAccountBalance(currencyId, account.address)
            totalTokensHeld += tokens

        # Ensure that total supply equals tokens held
        assert totalTokensHeld == totalSupply

        # Ensure that the perp token never holds other balances
        for (_, testCurrencyId) in env.currencyId.items():
            (cashBalance, tokens, lastMintTime) = env.router["Views"].getAccountBalance(
                testCurrencyId, perpToken.address
            )
            assert tokens == 0
            assert lastMintTime == 0

            if testCurrencyId != currencyId:
                assert cashBalance == 0

        # TODO: ensure that the perp token holds enough PV for negative fcash balances
        # TODO: ensure that the FC of the perp token is gte 0


def check_portfolio_invariants(env, accounts):
    fCash = defaultdict(dict)
    liquidityToken = defaultdict(dict)

    for account in accounts:
        portfolio = env.router["Views"].getAccountPortfolio(account.address)
        for asset in portfolio:
            if asset[2] == 1:
                if (asset[0], asset[1]) in fCash:
                    # Is fCash asset type, fCash[currencyId][maturity]
                    fCash[(asset[0], asset[1])] += asset[3]
                else:
                    fCash[(asset[0], asset[1])] = asset[3]
            else:
                if (asset[0], asset[1], asset[2]) in liquidityToken:
                    # Is liquidity token, liquidityToken[currencyId][maturity][assetType]
                    # Each liquidity token is indexed by its type and settlement date
                    liquidityToken[(asset[0], asset[1], asset[2])] += asset[3]
                else:
                    liquidityToken[(asset[0], asset[1], asset[2])] = asset[3]

        # TODO: check for ifCash assets here too

    # Check perp token portfolios
    for (currencyId, perpToken) in env.perpToken.items():
        portfolio = env.router["Views"].getAccountPortfolio(perpToken.address)

        for asset in portfolio:
            # Perp token cannot have any other currencies in its portfolio
            assert asset[0] == currencyId
            if asset[2] == 1:
                if (asset[0], asset[1]) in fCash:
                    # Is fCash asset type, fCash[currencyId][maturity]
                    fCash[(asset[0], asset[1])] += asset[3]
                else:
                    fCash[(asset[0], asset[1])] = asset[3]
            else:
                if (asset[0], asset[1], asset[2]) in liquidityToken:
                    # Is liquidity token, liquidityToken[currencyId][maturity][assetType]
                    # Each liquidity token is indexed by its type and settlement date
                    liquidityToken[(asset[0], asset[1], asset[2])] += asset[3]
                else:
                    liquidityToken[(asset[0], asset[1], asset[2])] = asset[3]

        ifCashAssets = env.router["Views"].getifCashAssets(perpToken.address)
        for asset in ifCashAssets:
            assert asset[0] == currencyId
            if (asset[0], asset[1]) in fCash:
                # Is fCash asset type, fCash[currencyId][maturity]
                fCash[(asset[0], asset[1])] += asset[3]
            else:
                fCash[(asset[0], asset[1])] = asset[3]

    # Check fCash in markets
    for (_, currencyId) in env.currencyId.items():
        markets = get_all_markets(env, currencyId)
        for marketGroup in markets:
            for (i, m) in enumerate(marketGroup):
                # Add total fCash in market
                assert m[2] >= 0
                if (currencyId, m[1]) in fCash:
                    # Is fCash asset type, fCash[currencyId][maturity]
                    fCash[(currencyId, m[1])] += m[2]
                else:
                    fCash[(currencyId, m[1])] = m[2]

                # Assert that total liquidity equals the tokens in portfolios
                if m[4] > 0:
                    assert liquidityToken[(currencyId, m[1], 2 + i)] == m[4]
                elif m[4] == 0:
                    assert (currencyId, m[1], 2 + i) not in liquidityToken
                else:
                    # Should never be zero
                    assert False

    for (_, netfCash) in fCash.items():
        # Assert that all fCash balances net off to zero
        assert netfCash == 0


def check_account_context(env, accounts):
    for account in accounts:
        context = env.router["Views"].getAccountContext(account.address)
        activeCurrencies = list(bytes_to_list(context[-1]))

        hasDebt = False
        for (_, currencyId) in env.currencyId.items():
            # Checks that active currencies is set properly
            (cashBalance, perpTokenBalance, lastMintTime) = env.router["Views"].getAccountBalance(
                currencyId, account.address
            )
            if cashBalance != 0 or perpTokenBalance != 0:
                assert currencyId in activeCurrencies

            if cashBalance < 0:
                hasDebt = True

        portfolio = env.router["Views"].getAccountPortfolio(account.address)
        nextMaturity = 0
        if len(portfolio) > 0:
            nextMaturity = portfolio[0][1]

        for asset in portfolio:
            # Check that currency id is in the active currencies list
            assert asset[0] in activeCurrencies

            if asset[1] < nextMaturity:
                # Set to the lowest maturity
                nextMaturity = asset[1]

            if asset[3] < 0:
                # Negative fcash
                hasDebt = True

        # Check next maturity, TODO: this does not work with idiosyncratic accounts
        assert context[0] == nextMaturity
        # Check that has debt is set properly
        assert context[1] == hasDebt
