from brownie import MockERC20, Views  # MockAggregator,; nCErc20,
from brownie.network.contract import Contract
from rich.console import Console
from rich.table import Table

console = Console()


def print_currencies(currencyAndRate):
    table = Table(title="Currencies Listed: {}".format(len(currencyAndRate)))

    table.add_column("ID", justify="right", style="cyan", no_wrap=True)
    table.add_column("Symbol", style="magenta")
    table.add_column("Has Fee", justify="right", style="green")
    table.add_column("Decimals", justify="right", style="green")
    table.add_column("ETH Rate", justify="right", style="green")
    table.add_column("Buffer", justify="right", style="green")
    table.add_column("Haircut", justify="right", style="green")
    table.add_column("Liquidation Discount", justify="right", style="green")

    for i, (currency, rate) in enumerate(currencyAndRate):
        erc20 = Contract.from_abi("erc20", currency[0], abi=MockERC20.abi, owner=None)
        symbol = erc20.symbol()
        table.add_row(
            str(i + 1),
            symbol,
            str(currency[1]),
            str(currency[2]),
            str(rate[1] / rate[0]),
            str(rate[2]),
            str(rate[3]),
            str(rate[4]),
        )

    console.print(table)


def print_cash_groups(cashGroupsAndRate, currencyAndRate):
    numCashGroups = len(list(filter(lambda x: x[0][0] != 0, cashGroupsAndRate)))
    table = Table(title="Cash Groups Listed: {}".format(numCashGroups))

    table.add_column("ID", justify="right", style="cyan", no_wrap=True)
    table.add_column("Symbol", style="magenta")
    table.add_column("Asset Rate", justify="right", style="green")
    table.add_column("Max Markets", justify="right", style="green")
    table.add_column("Rate Oracle Time (min)", justify="right", style="green")
    table.add_column("Liquidity Fee (bps)", justify="right", style="green")
    table.add_column("Token Haircut (%)", justify="right", style="green")
    table.add_column("Debt Buffer (BPS)", justify="right", style="green")
    table.add_column("fCash Haircut (BPS)", justify="right", style="green")
    table.add_column("Rate Scalar", justify="right", style="green")

    for i, (cg, rate) in enumerate(cashGroupsAndRate):
        if cg[0] == 0:
            continue

        erc20 = Contract.from_abi("erc20", currencyAndRate[i][0][0], abi=MockERC20.abi, owner=None)
        symbol = erc20.symbol()
        table.add_row(str(i + 1), symbol, str(rate[1] / 10 ** rate[2]), *[x for x in map(str, cg)])

    console.print(table)


def list_currencies(proxy, deployer):
    views = Contract.from_abi("Views", proxy.address, abi=Views.abi, owner=deployer)
    maxCurrencyId = views.getMaxCurrencyId()

    currencyAndRate = []
    for i in range(1, maxCurrencyId + 1):
        currencyAndRate.append(views.getCurrencyAndRate(i))

    print_currencies(currencyAndRate)

    cashGroupsAndRate = []
    for i in range(1, maxCurrencyId + 1):
        cashGroupsAndRate.append(views.getCashGroupAndRate(i))

    print_cash_groups(cashGroupsAndRate, currencyAndRate)
