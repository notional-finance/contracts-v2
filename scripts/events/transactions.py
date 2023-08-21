from collections import defaultdict

def find(arr, func):
    return next(filter(func, arr), None)

def sortByMaturity(arr):
    return sorted(arr, key=lambda a: a['maturity'])


def extract_mint_ntoken(transfers, _):
    liquidity = sortByMaturity([
        {
            'netfCash':  t['value'] if t['bundleName'] == 'nToken Add Liquidity' else -t['value'],
            'maturity': t['maturity']
        } 
        for t in transfers
        if t['bundleName'] in ['nToken Remove Liquidity', 'nToken Add Liquidity'] and t['value'] > 0
    ])
    feesPaidToReserve = sum([
       t['value'] for t in transfers if t['toSystemAccount']  == 'Fee Reserve'
    ])
    depositAmount = find(transfers, lambda x: x['bundleName'] == 'Mint nToken' and x['assetType'] == 'pCash')['value']
    mintNToken = find(transfers, lambda x: x['bundleName'] == 'Mint nToken' and x['assetType'] == 'nToken')
    minter = mintNToken['to']
    nTokensMinted = mintNToken['value']
    return {
        "minter": minter,
        "deposit": depositAmount,
        "nTokensMinted": nTokensMinted,
        "netLiquidity": liquidity,
        "feesPaidToReserve": feesPaidToReserve
    }

def extract_account_action(transfers, marker):
    account = marker['event']['account']
    netfCashAssets = defaultdict(lambda: 0)
    netCash = defaultdict(lambda: 0)
    netNTokens = defaultdict(lambda: 0)
    incentivesEarned = 0
    feesPaidToReserve = defaultdict(lambda: 0)

    for t in transfers:
        if t['assetType'] == 'fCash' and t['from'] == account:
            netfCashAssets[(t['underlying'], t['maturity'])] -= t['value']
        if t['assetType'] == 'fCash' and t['to'] == account:
            netfCashAssets[(t['underlying'], t['maturity'])] += t['value']

        if t['assetType'] == 'pCash' and t['from'] == account:
            netCash[t['underlying']] -= t['value']
        if t['assetType'] == 'pCash' and t['to'] == account:
            netCash[t['underlying']] += t['value']

        if t['assetType'] == 'nToken' and t['from'] == account:
            netNTokens[t['underlying']] -= t['value']
        if t['assetType'] == 'nToken' and t['to'] == account:
            netNTokens[t['underlying']] += t['value']

        if t['assetType'] == 'NOTE' and t['to'] == account:
            incentivesEarned += t['value']

        if t['assetType'] == 'pCash' and t['from'] == account and t['toSystemAccount'] == 'Fee Reserve':
            feesPaidToReserve[t['underlying']] += t['value']

    return {
        'account': account,
        'netfCashAssets': netfCashAssets,
        'netCash': netCash,
        'feesPaidToReserve': feesPaidToReserve,
        'netNTokens': netNTokens,
        'incentivesEarned': incentivesEarned
    }

def extract_redeem_ntoken(transfers, _):
    # Extract:
    #   - redemer account
    #   - amount withdrawn
    #   - per market [ net fcash liquidity, net cash liquidity ]
    #   - per fcash asset [ residual transfer, net cash from sale ]
    redeemed = [t for t in transfers if t['bundleName'] == 'Redeem nToken' and t['assetType'] == 'nToken']
    withdrawAmount = transfers[-2]['value']
    redeemer = redeemed[0]['from']
    nTokensRedeemed = redeemed[0]['value']

    liquidity = sortByMaturity([
        {
            'netfCash':  t['value'] if t['bundleName'] == 'nToken Add Liquidity' else -t['value'],
            'maturity': t['maturity']
        } 
        for t in transfers
        if t['bundleName'] in ['nToken Remove Liquidity', 'nToken Add Liquidity'] and t['value'] > 0 and t['assetType'] == 'fCash'
    ])
    residuals = sortByMaturity([
        {
            'residual':  t['value'],
            'maturity': t['maturity']
        } 
        for t in transfers
        if t['bundleName']  == 'nToken Residual Transfer' and t['assetType'] == 'fCash'
    ])
    assetsSold = [
       -t['value'] if t['bundleName'] == 'Buy fCash' else t['value']
        for t in transfers
        if t['bundleName'] in ['Buy fCash', 'Sell fCash']
            and t['assetType'] == 'pCash'
            and t['toSystemAccount'] != 'Fee Reserve'
    ]

    return {
        "redeemer": redeemer,
        "withdraw": withdrawAmount,
        "nTokensRedeemed": nTokensRedeemed,
        "liquidity": liquidity,
        "residuals": residuals,
        "assetsSold": assetsSold
    }

def extract_init_markets(transfers, _):
    newLiquidity = sortByMaturity([
        {
            'netfCash':  t['value'],
            'maturity': t['maturity']
        } 
        for t in transfers
        if t['bundleName'] in ['nToken Add Liquidity'] and t['value'] > 0
    ])
    
    return {
        # "totalSettledCash": totalSettledCash,
        # "residuals": residuals,
        "newLiquidity": newLiquidity
    }

def extract_settled_account(transfers, marker):
            # Extract:
            #   - settled account
            #   - [ fcash settled, maturity, settlement rate, additional debt accrued ]
    return {
        "settledAccount": transfers[-1]['to']
    }

def extract_liquidation(transfers, marker):
    account = marker['event']['liquidated']
    liquidator = marker['event']['liquidator']
    if 'collateralCurrencyId' in marker['event']:
        collateralCurrencyId = marker['event']['collateralCurrencyId']
    elif 'fCashCurrency' in marker['event']:
        collateralCurrencyId = marker['event']['fCashCurrency']
    else:
        collateralCurrencyId = None

    assetsToLiquidator = [
        {
            'underlying': t['underlying'],
            'assetType': t['assetType'],
            'value': t['value'],
            'maturity': t['maturity'] if 'maturity' in t else None
        } for t in transfers
        if t['to'] == liquidator and t['fromSystemAccount'] is None and t['transferType'] == 'Transfer'
    ]
    assetsToAccount = [
        {
            'underlying': t['underlying'],
            'assetType': t['assetType'],
            'value': t['value'],
            'maturity': t['maturity'] if 'maturity' in t else None
        } for t in transfers
        if t['to'] == account and t['fromSystemAccount'] is None and t['transferType'] == 'Transfer'
    ]
    return {
        "account": account,
        "liquidator": liquidator,
        "localCurrency": marker['event']['localCurrencyId'],
        "collateralCurrency": collateralCurrencyId,
        "assetsToAccount": assetsToAccount,
        "assetsToLiquidator": assetsToLiquidator,
    }

def extract_vault_entry(transfers, _):
    vaultShares = find(transfers, lambda t: t['assetType'] == 'Vault Share')
    vaultDebt = find(transfers, lambda t: t['assetType'] == 'Vault Debt')
    deposit = find(transfers, lambda t: t['bundleName'] == 'Deposit and Transfer' and t['transferType'] == 'Transfer')
    feesPaid = sum([t['value'] for t in transfers if t['bundleName'] == 'Vault Fees' or t['toSystemAccount'] == 'Fee Reserve'])

    return {
        'vault': vaultShares['vaultAddress'],
        'account': vaultShares['to'],
        'maturity': vaultShares['maturity'],
        'debtAmount': vaultDebt['value'],
        'marginDeposit': deposit['value'] if deposit else None,
        'feesPaid': feesPaid
    }

def extract_vault_exit(transfers, _):
    vaultShares = find(transfers, lambda t: t['assetType'] == 'Vault Share')
    vaultDebt = find(transfers, lambda t: t['assetType'] == 'Vault Debt')
    # add amount withdrawn, amount repaid, receiver
    feesPaid = sum([t['value'] for t in transfers if t['bundleName'] == 'Vault Fees' or t['toSystemAccount'] == 'Fee Reserve'])
    lendAtZero = find(transfers, lambda t: t['bundleName'] == 'Vault Lend at Zero') is not None

    return {
        'vault': vaultShares['vaultAddress'],
        'account': vaultShares['from'],
        'maturity': vaultShares['maturity'],
        'debtRepaid': vaultDebt['value'],
        'vaultRedeemed': vaultShares['value'],
        'feesPaid': feesPaid,
        'lendAtZero': lendAtZero
    }

def extract_vault_roll(transfers, _):
    oldVaultShares = find(transfers, lambda t: t['assetType'] == 'Vault Share' and t['transferType'] == 'Burn')
    vaultShares = find(transfers, lambda t: t['assetType'] == 'Vault Share' and t['transferType'] == 'Mint')
    vaultDebt = find(transfers, lambda t: t['assetType'] == 'Vault Debt' and t['transferType'] == 'Mint')
    # add amount withdrawn, amount repaid, receiver
    feesPaid = sum([t['value'] for t in transfers if t['bundleName'] == 'Vault Fees' or t['toSystemAccount'] == 'Fee Reserve'])
    lendAtZero = find(transfers, lambda t: t['bundleName'] == 'Vault Lend at Zero') is not None

    return {
        'vault': vaultShares['vaultAddress'],
        'account': vaultShares['to'],
        'oldMaturity': oldVaultShares['maturity'],
        'newMaturity': vaultShares['maturity'],
        'debtAmount': vaultDebt['value'],
        'vaultShares': vaultShares['value'],
        'feesPaid': feesPaid,
        'lendAtZero': lendAtZero
    }

def extract_vault_settle(transfers, _):
    vaultShares = find(transfers, lambda t: t['assetType'] == 'Vault Share' and t['transferType'] == 'Mint')
    vaultDebt = find(transfers, lambda t: t['assetType'] == 'Vault Debt' and t['transferType'] == 'Mint')
    # add amount withdrawn, amount repaid, receiver
    feesPaid = sum([t['value'] for t in transfers if t['bundleName'] == 'Vault Fees' or t['toSystemAccount'] == 'Fee Reserve'])

    return {
        'vault': vaultShares['vaultAddress'],
        'account': vaultShares['to'],
        'debtAmount': vaultDebt['value'],
        'vaultShares': vaultShares['value'],
        'feesPaid': feesPaid
    }

def extract_vault_deleverage(transfers, _):
    return {
        # 'vault': vaultShares['vaultAddress'],
        # 'account': vaultShares['from'],
        # 'liquidator': None,
        # 'vaultSharesToLiquidator': vaultShares
        # 'cashToAccount': deposit
    }

def extract_vault_liquidate_cash(transfers, _):
    return {
        # 'vault': vaultShares['vaultAddress'],
        # 'account': vaultShares['from'],
        # 'liquidator': None,
        # 'fCashDebtRepaid': vaultShares
        # 'cashToLiquidator': deposit
    }

typeMatchers = [
    { 'transactionType': 'Mint nToken', 'pattern': [
        {'op': '*', 'exp': ['nToken Add Liquidity', 'nToken Deleverage', 'nToken Remove Liquidity']},
        {'op': '.', 'exp': ['Mint nToken']},
    ], 'extractor': extract_mint_ntoken},
    { 'transactionType': 'Redeem nToken', 'pattern': [
        {'op': '+', 'exp': ['nToken Remove Liquidity']},
        {'op': '.', 'exp': ['Redeem nToken']},
        {'op': '*', 'exp': ['Buy fCash', 'Sell fCash', 'nToken Residual Transfer', 'Borrow fCash', 'Transfer Incentive',
                            'Repay Prime Cash', 'Repay fCash']},
    ], 'extractor': extract_redeem_ntoken},
    { 'transactionType': 'Initialize Markets', 'endMarkers': ['MarketsInitialized'], 'pattern': [
        {'op': '.', 'exp': ['Global Settlement']},
        {'op': '+', 'exp': ['Settle fCash nToken', 'Settle Cash nToken', 'nToken Remove Liquidity']},
        {'op': '?', 'exp': ['Repay Prime Cash']}, # This occurs on negative residuals
        {'op': '+', 'exp': ['nToken Add Liquidity']},
    ], 'extractor': extract_init_markets},
    { 'transactionType': 'Initialize Markets [First Init]', 'endMarkers': ['MarketsInitialized'], 'pattern': [
        {'op': '+', 'exp': ['nToken Add Liquidity']},
    ], 'extractor': extract_init_markets},
    { 'transactionType': 'Sweep Cash into Markets', 'endMarkers': ['SweepCashIntoMarkets'], 'pattern': [
        {'op': '+', 'exp': ['nToken Add Liquidity']},
    ], 'extractor': extract_init_markets},
    { 'transactionType': 'Settle Account', 'endMarkers': ['AccountSettled'], 'pattern': [
        {'op': '+', 'exp': ['Settle fCash', 'Settle Cash']},
    ], 'extractor': extract_settled_account},
    { 'transactionType': 'Liquidation', 'endMarkers': ['LiquidateLocalCurrency', 'LiquidateCollateralCurrency', 'LiquidatefCashEvent'], 'pattern': [ 
        {'op': '?', 'exp': ['Deposit and Transfer']},
        {'op': '+', 'exp': ['Transfer Asset', 'Transfer Incentive', 'Repay Prime Cash', 'Borrow Prime Cash', 'Repay fCash']},
        {'op': '?', 'exp': ['Withdraw']},
    ], 'extractor': extract_liquidation},
    { 'transactionType': 'Vault Entry', 'pattern': [
        {'op': '?', 'exp': ['Deposit and Transfer']},
        # TODO: just make one list which is vault ops
        {'op': '+', 'exp': ['Sell fCash [Vault]', 'Vault Fees', 'Vault Entry Transfer', 'Borrow fCash [Vault]',
                            'Settle Cash', 'Settle fCash', 'Borrow Prime Cash [Vault]', 'Vault Secondary Borrow', 'Vault Burn Cash']},
        {'op': '.', 'exp': ['Vault Entry']}
    ], 'extractor': extract_vault_entry},
    { 'transactionType': 'Vault Exit', 'pattern': [
        {'op': '+', 'exp': ['Buy fCash [Vault]', 'Vault Redeem', 'Repay fCash [Vault]', 'Vault Secondary Repay', 'Vault Fees',
                            'Settle Cash', 'Settle fCash', 'Borrow Prime Cash [Vault]', 'Repay Prime Cash [Vault]', 'Deposit and Transfer',
                            'Withdraw', 'Vault Lend at Zero', 'Vault Burn Cash', 'Vault Withdraw Cash']},
        {'op': '.', 'exp': ['Vault Exit']}
    ], 'extractor': extract_vault_exit},
    { 'transactionType': 'Vault Roll', 'pattern': [
        {'op': '+', 'exp': ['Buy fCash [Vault]', 'Deposit and Transfer', 'Sell fCash [Vault]', 'Vault Fees', 'Vault Entry Transfer',
                            'Borrow fCash [Vault]', 'Repay fCash [Vault]', 'Vault Secondary Borrow', 'Vault Secondary Repay',
                            'Vault Lend at Zero', 'Repay Prime Cash [Vault]', 'Borrow Prime Cash [Vault]', 'Vault Burn Cash']},
        # TODO: this fails because vault exit gets re-written to vault roll in the bundle
        {'op': '.', 'exp': ['Vault Roll']},
    ], 'extractor': extract_vault_roll},
    { 'transactionType': 'Vault Settle', 'pattern': [
        {'op': '*', 'exp': [ 'Vault Secondary Settle', 'Borrow Prime Cash [Vault]', 'Vault Fees',
                            'Settle Cash', 'Settle fCash', 'Repay Prime Cash [Vault]', 'Deposit and Transfer', 'Vault Settle Cash']},
        {'op': '.', 'exp': ['Vault Settle']}
    ], 'extractor': extract_vault_settle},
    { 'transactionType': 'Vault Deleverage [Prime]', 'pattern': [
        {'op': '?', 'exp': ['Borrow Prime Cash [Vault]']},
        {'op': '?', 'exp': ['Vault Fees']},
        {'op': '.', 'exp': ['Deposit and Transfer']},
        {'op': '.', 'exp': ['Vault Deleverage Prime Debt']},
        {'op': '.', 'exp': ['Repay Prime Cash [Vault]']}
    ], 'extractor': extract_vault_deleverage},
    { 'transactionType': 'Vault Deleverage [fCash]', 'pattern': [
        {'op': '.', 'exp': ['Deposit and Transfer']},
        {'op': '.', 'exp': ['Vault Deleverage fCash']},
    ], 'extractor': extract_vault_deleverage},
    { 'transactionType': 'Vault Liquidate Cash', 'pattern': [
        {'op': '.', 'exp': ['Vault Liquidate Cash']},
    ], 'extractor': extract_vault_liquidate_cash},
    { 'transactionType': 'Vault Liquidate Excess Cash', 'pattern': [
        {'op': '.', 'exp': ['Vault Liquidate Excess Cash']},
    ], 'extractor': extract_vault_liquidate_cash},
    { 'transactionType': 'Account Action', 'endMarkers': ['AccountContextUpdate'], 'pattern': [
        # TODO: note this does not actually work for minting / redeeming nTokens b/c they get
        # captured by the other group
        {'op': '+', 'exp': [
            'Borrow Prime Cash',
            'Repay Prime Cash',
            'Borrow fCash',
            'Repay fCash',
            'Buy fCash',
            'Sell fCash',
            'nToken Purchase Negative Residual',
            'nToken Purchase Positive Residual',
            'Transfer Asset',
            'Transfer Incentive',
            'Deposit',
            'Withdraw',
        ]},
    ], 'extractor': extract_account_action},
]