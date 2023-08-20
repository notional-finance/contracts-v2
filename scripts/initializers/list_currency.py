from brownie import Contract, accounts, interface
from scripts.arbitrum.arb_config import ListedTokens
from scripts.arbitrum.arb_deploy import _deploy_chainlink_oracle, _deploy_pcash_oracle, _to_interest_rate_curve
from scripts.common import TokenType
from scripts.inspect import get_addresses

def donate_initial(symbol, notional, fundingAccount):
    token = ListedTokens[symbol]
    if symbol == 'ETH':
        fundingAccount.transfer(notional, 0.01e18)
    else:
        erc20 = Contract.from_abi("token", token['address'], interface.IERC20.abi)
        # Donate the initial balance
        erc20.transfer(notional, 0.05 * 10 ** erc20.decimals(), {"from": fundingAccount})

def list_currency(notional, symbol):
    token = ListedTokens[symbol]
    callData = []

    txn = notional.listCurrency(
        (
            token['address'],
            False,
            TokenType["UnderlyingToken"] if symbol != "ETH" else TokenType["Ether"],
            token['decimals'],
            0,
        ),
        (
            token['ethOracle'],
            18,
            False,
            token["buffer"],
            token["haircut"],
            token["liquidationDiscount"],
        ),
        _to_interest_rate_curve(token['primeCashCurve']),
        token['pCashOracle'],
        True,  # allowDebt
        token['primeRateOracleTimeWindow5Min'],
        token['name'],
        symbol,
        {"from": notional.owner()}
    )
    currencyId = txn.events["ListCurrency"]["newCurrencyId"]

    txn = notional.enableCashGroup(
        currencyId,
        (
            token["maxMarketIndex"],
            token["rateOracleTimeWindow"],
            token["maxDiscountFactor"],
            token["reserveFeeShare"],
            token["debtBuffer"],
            token["fCashHaircut"],
            token["minOracleRate"],
            token["liquidationfCashDiscount"],
            token["liquidationDebtBuffer"],
            token["maxOracleRate"]
        ),
        token['name'],
        symbol,
        {"from": notional.owner()}
    )

    notional.updateInterestRateCurve(
        currencyId,
        [1, 2],
        [_to_interest_rate_curve(c) for c in token['fCashCurves']],
        {"from": notional.owner()}
    )

    notional.updateDepositParameters(currencyId, token['depositShare'], token['leverageThreshold'], {"from": notional.owner()})

    notional.updateInitializationParameters(currencyId, [0, 0], token['proportion'], {"from": notional.owner()})

    notional.updateTokenCollateralParameters(
        currencyId,
        token["residualPurchaseIncentive"],
        token["pvHaircutPercentage"],
        token["residualPurchaseTimeBufferHours"],
        token["cashWithholdingBuffer10BPS"],
        token["liquidationHaircutPercentage"],
        {"from": notional.owner()}
    )

    notional.setMaxUnderlyingSupply(currencyId, token['maxUnderlyingSupply'], {"from": notional.owner()})

def main():
    fundingAccount = accounts.at("0x7d7935EDd4b6cDB5f34B0E1cCEAF85a3C4A11254", force=True)
    (addresses, notional, note, router, networkName) = get_addresses()
    donate_initial(notional, fundingAccount)

    # deployer = accounts.load(networkName.upper() + "_DEPLOYER")
    # _deploy_pcash_oracle('rETH', notional, deployer)
    # _deploy_pcash_oracle('USDT', notional, deployer)
    # _deploy_chainlink_oracle('USDT', deployer)

    print("NETWORK NAME", networkName)
    # list_currency(notional, 'rETH')