from brownie import Contract, accounts, interface
from scripts.arbitrum.arb_config import ListedTokens
from scripts.arbitrum.arb_deploy import _deploy_chainlink_oracle, _deploy_pcash_oracle, _to_interest_rate_curve
from scripts.common import TokenType
from scripts.inspect import get_addresses
import json
from tests.helpers import get_balance_action

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
    # currencyId = txn.events["ListCurrency"]["newCurrencyId"]
    currencyId = 7 if symbol == 'rETH' else 8
    callData.append(txn.input)

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
    callData.append(txn.input)

    txn = notional.updateInterestRateCurve(
        currencyId,
        [1, 2],
        [_to_interest_rate_curve(c) for c in token['fCashCurves']],
        {"from": notional.owner()}
    )
    callData.append(txn.input)

    txn = notional.updateDepositParameters(currencyId, token['depositShare'], token['leverageThreshold'], {"from": notional.owner()})
    callData.append(txn.input)

    txn = notional.updateInitializationParameters(currencyId, [0, 0], token['proportion'], {"from": notional.owner()})
    callData.append(txn.input)

    txn = notional.updateTokenCollateralParameters(
        currencyId,
        token["residualPurchaseIncentive"],
        token["pvHaircutPercentage"],
        token["residualPurchaseTimeBufferHours"],
        token["cashWithholdingBuffer10BPS"],
        token["liquidationHaircutPercentage"],
        {"from": notional.owner()}
    )
    callData.append(txn.input)

    txn = notional.setMaxUnderlyingSupply(currencyId, token['maxUnderlyingSupply'], {"from": notional.owner()})
    callData.append(txn.input)

    return callData

def main():
    fundingAccount = accounts.at("0x7d7935EDd4b6cDB5f34B0E1cCEAF85a3C4A11254", force=True)
    (addresses, notional, note, router, networkName) = get_addresses()
    # donate_initial('rETH', notional, fundingAccount)
    # donate_initial('USDT', notional, fundingAccount)

    # deployer = accounts.load(networkName.upper() + "_DEPLOYER")
    # _deploy_pcash_oracle('rETH', notional, deployer)
    # _deploy_pcash_oracle('USDT', notional, deployer)
    # _deploy_chainlink_oracle('USDT', deployer)
    batchBase = {
        "version": "1.0",
        "chainId": "42161",
        "createdAt": 1692567274357,
        "meta": {
            "name": "Transactions Batch",
            "description": "",
            "txBuilderVersion": "1.16.1"
        },
        "transactions": []
    }

    callData = list_currency(notional, 'rETH')
    for data in callData:
        batchBase['transactions'].append({
            "to": notional.address,
            "value": "0",
            "data": data,
            "contractMethod": { "inputs": [], "name": "fallback", "payable": True },
            "contractInputsValues": None
        })
    json.dump(batchBase, open("batch-reth.json", 'w'))

    batchBase['transactions'] = []
    callData = list_currency(notional, 'USDT')
    for data in callData:
        batchBase['transactions'].append({
            "to": notional.address,
            "value": "0",
            "data": data,
            "contractMethod": { "inputs": [], "name": "fallback", "payable": True },
            "contractInputsValues": None
        })
    json.dump(batchBase, open("batch-usdt.json", 'w'))

    # Mint nTokens and Init Markets
    token = ListedTokens['rETH']
    erc20 = Contract.from_abi("token", token['address'], interface.IERC20.abi)
    erc20.approve(notional, 2 ** 255, {"from": fundingAccount})

    token = ListedTokens['USDT']
    erc20 = Contract.from_abi("token", token['address'], interface.IERC20.abi)
    erc20.approve(notional, 2 ** 255, {"from": fundingAccount})

    notional.batchBalanceAction(fundingAccount, [
        get_balance_action(
            7, "DepositUnderlyingAndMintNToken", depositActionAmount=0.01e18
        ),
        get_balance_action(
            8, "DepositUnderlyingAndMintNToken", depositActionAmount=100e6
        )
    ], {'from': fundingAccount})
    notional.initializeMarkets(7, True, {'from': fundingAccount})
    notional.initializeMarkets(8, True, {'from': fundingAccount})