import logging
from brownie import ZERO_ADDRESS
from scripts.events.bundles import bundleCriteria
from scripts.events.transactions import typeMatchers
from tests.constants import FEE_RESERVE, SETTLEMENT_RESERVE

LOGGER = logging.getLogger(__name__)

def findIndex(arr, func):
    for (i, v) in enumerate(arr):
        if func(v): return i
    return -1

def findLastIndex(arr, func):
    length = len(arr)
    # Iterate in reverse order
    for i in range(length - 1, -1, -1):
        if func(arr[i]): return i
    return -1

def find(arr, func):
    return next(filter(func, arr), None)

def processTxn(environment, txn):
    # Events go through three levels of processing to mirror what will happen in the subgraph
    #   - Events are decoded into individual transfers on a single transaction hash
    #   - As they are decoded, a series of window functions are applied to categorize series of
    #     transfers into a "transfer bundle" which is mutually exclusive and named.
    #   - Another set of window functions are applied that look at the "transfer bundle" and
    #     categorize them into a "transaction group" which signifies a logical execution on
    #     Notional.
    eventStore = {
        'hash': txn.txid,
        'transfers': [],
        'bundles': [],
        'transactionTypes': [],
        'markers': []
    }

    for e in txn.events:
        bundleId = None
        if isValidTransfer(environment, e):
            decodeEvent(environment, eventStore, e, txn)
            bundleId = scanTransferBundle(eventStore, txn.txid)
        elif isMarker(environment, e):
            eventStore['markers'].append({
                'name': e.name,
                'event': e,
                'logIndex': e.pos[0]
            })

    # Scan transactions after all bundles have been marked
    i = 0
    while i < 3: 
        if scanTransactionType(eventStore, txn.txid) is None:
            break
        i += 1
    LOGGER.info("finished process txn")

    return eventStore

def isMarker(environment, e):
    return e.address == environment.notional.address and e.name in [
        'MarketsInitialized',
        'SweepCashIntoMarkets',
        'AccountSettled',
        'AccountContextUpdate',
        'LiquidateLocalCurrency',
        'LiquidateCollateralCurrency',
        'LiquidatefCashEvent'
    ]

def isValidTransfer(environment, e):
    return (
        e.address in environment.proxies and e.name == 'Transfer' or
        e.address == environment.notional.address and e.name in ['TransferSingle', 'TransferBatch'] or
        e.address == environment.noteERC20.address and e.name == 'Transfer'
    )

def decodeERC1155AssetType(assetType):
    if assetType == 1:
        return 'fCash'
    elif assetType == 9:
        return 'Vault Share'
    elif assetType == 10:
        return 'Vault Debt'
    elif assetType == 11:
        return 'Vault Cash'
    else:
        raise Exception("Unknown asset type", assetType)

def decodeAssetType(environment, e, index=0):
    if e.name == 'Transfer':
        # These will come from the subgraph DataStoreContext
        if e.address == environment.noteERC20:
            assetType = 'NOTE'
            currencyId = None
        else:
            assetType = environment.proxies[e.address]['assetType']
            currencyId = environment.proxies[e.address]['currencyId']

        return {
            'asset': e.address,
            'assetType': assetType,
            'assetInterface': 'ERC20',
            'underlying': currencyId,
            'value': e['value'] if 'value' in e else e['amount'],
        }
    elif e.name == 'TransferSingle':
        (currencyId, maturity, assetType, vaultAddress, isfCashDebt) = environment.notional.decodeERC1155Id(e['id'])

        return {
            'asset': e['id'],
            'assetType': decodeERC1155AssetType(assetType),
            'assetInterface': 'ERC1155',
            'underlying': currencyId,
            'value': -e['value'] if isfCashDebt else e['value'],
            'maturity': maturity,
            'vaultAddress': vaultAddress,
            'operator': e['operator']
            # TODO: convert to underlying present value here
        }
    elif e.name == 'TransferBatch':
        (currencyId, maturity, assetType, vaultAddress, isfCashDebt) = environment.notional.decodeERC1155Id(e['ids'][index])

        return {
            'asset': e['ids'][index],
            'assetType': decodeERC1155AssetType(assetType),
            'assetInterface': 'ERC1155',
            'underlying': currencyId,
            'value': -e['values'][index] if isfCashDebt else e['values'][index],
            'maturity': maturity,
            'vaultAddress': vaultAddress,
            'operator': e['operator']
            # TODO: convert to underlying present value here
        }


def getSystemAccount(environment, address):
    if address in environment.proxies and environment.proxies[address]['assetType'] == 'nToken':
        return 'nToken'
    elif address in environment.vaults:
        return 'Vault'
    elif address == SETTLEMENT_RESERVE:
        return 'Settlement'
    elif address == FEE_RESERVE:
        return 'Fee Reserve'
    elif address == environment.notional.address:
        return 'Notional'
    else:
        return None

def decodeTransferType(environment, e):
    if e['to'] == ZERO_ADDRESS:
        transferType = 'Burn'
    elif e['from'] == ZERO_ADDRESS:
        transferType = 'Mint'
    else:
        transferType = 'Transfer'

    return {
        'transferType': transferType,
        'fromSystemAccount': getSystemAccount(environment, e['from']),
        'toSystemAccount': getSystemAccount(environment, e['to'])
    }

def decodeTransfer(environment, eventStore, event, txn, index):
    transfer = {
        'id': "{}:{}:{}".format(txn.txid, event.pos[0], index),
        'blockNumber': txn.block_number,
        'timestamp': txn.timestamp,
        'transactionHash': txn.txid,
        'logIndex': event.pos[0],
        'from': event['from'],
        'to': event['to'],
    } | decodeAssetType(environment, event, index) | decodeTransferType(environment,event)

    eventStore['transfers'].append(transfer)

def decodeEvent(environment, eventStore, event, txn):
    if event.name == 'TransferBatch':
        for i in range(0, len(event['ids'])):
            decodeTransfer(environment, eventStore, event, txn, i)
    else:
        decodeTransfer(environment, eventStore, event, txn, 0)

def scanTransferBundle(eventStore, txid):
    # Find the last index of the transfers that has not been matched, matching is
    # mutually exclusive so each transfer cannot be in two bundles
    startIndex = findIndex(eventStore['transfers'], lambda t: 'bundleId' not in t)
    if startIndex == -1:
        # Should always have a final index here because we have just appended a transfer
        raise Exception("Invalid final index")

    for criteria in bundleCriteria:
        # Loop through all criteria where the window size is sufficient to bundle
        # the transfer set
        windowSize = criteria['windowSize']

        if len(eventStore['transfers']) - startIndex < windowSize:
            # Unbundled transfers do not match the window size
            continue

        lookBehind = 0
        if 'lookBehind' in criteria and startIndex < criteria['lookBehind']:
            if 'canStart' in criteria and criteria['canStart'] and startIndex == 0:
                # If the event type can be the starting point then ignore the lookBehind
                # at startIndex == 0
                lookBehind = 0
            else:
                # The final index has not progressed far enough to satisfy the lookback
                continue
        elif 'lookBehind' in criteria:
            lookBehind = criteria['lookBehind']

        # This window should match the entire length of unmatched transfers
        window = eventStore['transfers'][startIndex - lookBehind:startIndex + windowSize]
        if criteria['func'](window):
            bundleSize = windowSize
            if 'bundleSize' in criteria:
                bundleSize = criteria['bundleSize']

            bundleName = criteria['bundleName']
            startLogIndex = eventStore['transfers'][startIndex]['logIndex']
            endIndex = startIndex + bundleSize - 1
            endLogIndex = eventStore['transfers'][endIndex]['logIndex']
            bundleId = "{}:{}:{}:{}".format(txid, startLogIndex, endLogIndex, bundleName)

            if 'rewrite' in criteria and criteria['rewrite']:
                eventStore['bundles'].pop()
                for i in range(0, lookBehind):
                    eventStore['transfers'][startIndex - 1 - i]['bundleId'] = bundleId
                    eventStore['transfers'][startIndex - 1 - i]['bundleName'] = bundleName

            for i in range(0, bundleSize):
                eventStore['transfers'][startIndex + i]['bundleId'] = bundleId
                eventStore['transfers'][startIndex + i]['bundleName'] = bundleName

            eventStore['bundles'].append({
                'bundleId': bundleId,
                'bundleName': bundleName,
                'startLogIndex': startLogIndex,
                'endLogIndex': endLogIndex,
            })
            # Return the bundle id
            return bundleId
    return None

def scanTransactionType(eventStore, txid):
    # Find the last index where a transaction type has been categorized and start from the
    # next index after that
    startIndex = findLastIndex(eventStore['bundles'], lambda t: 'transactionTypeId' in t) + 1
    if startIndex == -1:
        # Should always have a start index here because we have just appended a bundle
        raise Exception("Invalid final index")

    for matcher in typeMatchers:
        (startMatch, endIndex, marker) = match(matcher, eventStore['bundles'], startIndex, eventStore['markers'])

        if startMatch is None:
            # Did not match so try the next matcher
            continue

        transactionType = matcher['transactionType']
        startLogIndex = eventStore['bundles'][startMatch]['startLogIndex']
        endLogIndex = eventStore['bundles'][endIndex]['endLogIndex']
        transactionTypeId = "{}:{}:{}:{}".format(txid, startLogIndex, endLogIndex, transactionType)

        transfers = []
        for i in range(startMatch, endIndex + 1):
            eventStore['bundles'][i]['transactionTypeId'] = transactionTypeId
            bundleId = eventStore['bundles'][i]['bundleId']

            for (i, t) in enumerate(eventStore['transfers']):
                if t['bundleId'] == bundleId:
                    eventStore['transfers'][i]['transactionTypeId'] = transactionTypeId
                    eventStore['transfers'][i]['transactionType'] = transactionType
                    transfers.append(eventStore['transfers'][i])

        eventStore['transactionTypes'].append({
            'transactionTypeId': transactionTypeId,
            'transactionType': transactionType
        } | matcher['extractor'](transfers, marker))

        return transactionTypeId

    return None

def match(matcher, bundles, startIndex, markers):
    pattern = matcher['pattern']

    # marker = None
    # if 'endMarkers' in matcher:
    #     startLogIndex = bundles[startIndex]['startLogIndex']
    #     marker = find(markers, lambda m: startLogIndex < m['logIndex'] and m['name'] in matcher['endMarkers'])
    #     if not marker:
    #         return (None, None, None)

    #     endLogIndex = marker['logIndex']
    #     bundles = list(filter(lambda b: b['endLogIndex'] <= endLogIndex, bundles))

    while startIndex < len(bundles):
        # if marker and marker['logIndex'] < bundles[startIndex]['startLogIndex']:
        #     # If the bundle start index has passed the marker's index then terminate the
        #     # search since the marker is required for termination
        #     return (None, None, None)
        bundlesLeft = match_here(pattern, bundles[startIndex:])
        if bundlesLeft == -1:
            startIndex += 1
            continue

        endIndex = len(bundles) - bundlesLeft - 1
        if 'endMarkers' in matcher:
            endLogIndex = bundles[endIndex]['endLogIndex']
            # Find the first marker past the end index that matches the pattern
            marker = find(markers, lambda m: endLogIndex < m['logIndex'] and m['name'] in matcher['endMarkers'])
            if marker:
                return (startIndex, endIndex, marker)
            else:
                startIndex += 1
        else:
            return (startIndex, endIndex, None)
    
    return (None, None, None)

def match_here(pattern, bundles):
    if len(pattern) == 0:
        # End of pattern, return the end index
        return len(bundles)
    elif pattern[0]['op'] == '.':
        if len(bundles) > 0 and bundles[0]['bundleName'] in pattern[0]['exp']:
            # Did match, go one level deeper
            return match_here(pattern[1:], bundles[1:])
        else:
            return -1
    elif pattern[0]['op'] == '?':
        if len(bundles) > 0 and bundles[0]['bundleName'] in pattern[0]['exp']:
            # Did match, move to next pattern
            return match_here(pattern[1:], bundles[1:])
        else:
            # Did not match, move to next pattern on current bundle
            return match_here(pattern[1:], bundles)
    elif pattern[0]['op'] == '!$':
        if len(pattern[1:]) > 0:
            raise Exception("!$ must terminate pattern")

        if len(bundles) == 0:
            return -1
        else:
            return 0 if bundles[0]['bundleName'] not in pattern[0]['exp'] else -1
    elif pattern[0]['op'] == '+':
        # Must match on the current bundle or fail
        if len(bundles) == 0 or bundles[0]['bundleName'] not in pattern[0]['exp']:
            return -1
        
        # Otherwise match like if it is a star op
        index = 0
        while index < len(bundles) and bundles[index]['bundleName'] in pattern[0]['exp']:
            index += 1

        return match_here(pattern[1:], bundles[index:])
    elif pattern[0]['op'] == '*':
        index = 0
        while  index < len(bundles) and bundles[index]['bundleName'] in pattern[0]['exp']:
            index += 1

        return match_here(pattern[1:], bundles[index:])
    else:
        raise Exception("Unknown op", pattern[0])
