import copy
import brownie
import pytest
from brownie import ZERO_ADDRESS, Wei, interface
from itertools import product
from brownie.network.state import Chain
from scripts.EventProcessor import processTxn
from tests.constants import FEE_RESERVE, PRIME_CASH_VAULT_MATURITY, SECONDS_IN_QUARTER, SETTLEMENT_RESERVE
from tests.helpers import get_tref

chain = Chain()

def get_vault_ids(environment, vault, currency):
    tref = get_tref(chain.time())
    maturities = [tref + SECONDS_IN_QUARTER for _ in range(-1, 5)]
    return [
        environment.notional.encode(currency, m, 9, vault, False)
        for  m in maturities
    ] + [
        environment.notional.encode(currency, m, 10, vault, False)
        for  m in maturities
    ] + [
        environment.notional.encode(currency, m, 11, vault, False)
        for  m in maturities
    ]


def get_snapshot(environment, accounts, additionalMaturities=[]):
    snapshot = {}
    allAccounts = [
        n.address for n in environment.nToken.values()
    ] + [
        a.address for a in accounts[0:3]
    ] + [
        FEE_RESERVE, ZERO_ADDRESS, environment.notional.address
    ] + [
        v.address for v in environment.vaults
    ]

    proxyAddresses = [ p for p in environment.proxies.keys() ] + [ environment.noteERC20.address ]
    for proxy in proxyAddresses:
        # WARNING: this changes the global state for an address, may affect event decoding
        erc20 = interface.IERC20(proxy)

        # Run this to get the fee reserve figure up to date
        # if proxy in environment.proxies:
        #     environment.notional.accruePrimeInterest(environment.proxies[proxy]['currencyId'])
        snapshot[proxy] = {}
        snapshot[proxy]['balanceOf'] = { a: erc20.balanceOf(a) for a in allAccounts }
        snapshot[proxy]['totalSupply'] = erc20.totalSupply()
        # TODO: this does not work for vaults
        if len(environment.vaults) > 0:
            continue

        # TODO: this does not work for the settlement reserve
        # TODO: this is a larger rounding error during liquidation
        if proxy in environment.proxies and environment.proxies[proxy]['symbol'] == 'pUSDC':
            assert pytest.approx(snapshot[proxy]['totalSupply'], abs=5_000) == sum(snapshot[proxy]['balanceOf'].values())
        else:
            assert pytest.approx(snapshot[proxy]['totalSupply'], abs=1_000) == sum(snapshot[proxy]['balanceOf'].values())

    tref = get_tref(chain.time())
    maturities = [tref + i * SECONDS_IN_QUARTER for i in range(-1, 4)] + additionalMaturities
    fCashIds = [ 
        environment.notional.encode(c, m, 1, ZERO_ADDRESS, isDebt)
        for (c, m, isDebt) in product(range(1, 5), maturities, [True, False])
    ]

    vaultIds = []
    if len(environment.vaults) > 0:
        vaultCurrencies = []
        config = environment.notional.getVaultConfig(environment.vaults[0])
        vaultCurrencies.append(config['borrowCurrencyId'])
        if config['secondaryBorrowCurrencies'][0] != 0:
            vaultCurrencies.append(config['secondaryBorrowCurrencies'][0])
        if config['secondaryBorrowCurrencies'][0] != 0:
            vaultCurrencies.append(config['secondaryBorrowCurrencies'][1])

        vaultIds = [ 
            environment.notional.encode(c, m, a, environment.vaults[0], False)
            for (a, m, c) in product([9, 10, 11], maturities + [PRIME_CASH_VAULT_MATURITY], vaultCurrencies)
        ]

    for id in fCashIds + vaultIds:
        snapshot[id] = {}
        snapshot[id]['balanceOf'] = { a: environment.notional.balanceOf(a, id) for a in allAccounts }

    return snapshot

def apply_transfers(snapshot, transfers):
    for t in transfers:
        if t['from'] == SETTLEMENT_RESERVE or t['to'] == SETTLEMENT_RESERVE:
            continue

        if t['from'] != ZERO_ADDRESS:
            snapshot[t['asset']]['balanceOf'][t['from']] -= abs(t['value'])
        if t['to'] != ZERO_ADDRESS:
            snapshot[t['asset']]['balanceOf'][t['to']] += abs(t['value'])

        if t['assetInterface'] == 'ERC20':
            if t['from'] == ZERO_ADDRESS:
                snapshot[t['asset']]['totalSupply'] += abs(t['value'])
            elif t['to'] == ZERO_ADDRESS:
                snapshot[t['asset']]['totalSupply'] -= abs(t['value'])

    return snapshot

def compare_snapshot(environment, snapshotBefore, transfers, context):
    feeBefore = [
        copy.copy(snapshotBefore[a]['balanceOf'][FEE_RESERVE])
        for a in environment.proxies
    ]
    simulatedSnapshot = apply_transfers(copy.copy(snapshotBefore), transfers)

    for asset in simulatedSnapshot.keys():
        if type(asset) == Wei:
            for account in simulatedSnapshot[asset]['balanceOf'].keys():
                # TODO: this does not work for vault total fCash
                if account in environment.vaults:
                    continue

                newBalance = environment.notional.balanceOf(account, asset)
                assert pytest.approx(simulatedSnapshot[asset]['balanceOf'][account], abs=10) == newBalance
        else:
            # WARNING: this changes the global state for an address, may affect event decoding
            erc20 = interface.IERC20(asset)
            for account in simulatedSnapshot[asset]['balanceOf'].keys():
                # Run this to get the fee reserve figure up to date
                # if asset in environment.proxies:
                #     accrue = environment.notional.accruePrimeInterest(environment.proxies[asset]['currencyId'])

                newBalance = erc20.balanceOf(account)

                # TODO: this does not work for vault total cash
                if account in environment.vaults:
                    continue
                # TODO: withdraw prime cash has rounding errors
                if asset in environment.proxies and environment.proxies[asset]['symbol'] == 'pUSDC':
                    pass
                    assert pytest.approx(simulatedSnapshot[asset]['balanceOf'][account], abs=5_000) == newBalance
                else:
                    # TODO: inside liquidation this rounding error is higher
                    assert pytest.approx(simulatedSnapshot[asset]['balanceOf'][account], abs=1_000) == newBalance

class EventChecker():

    def __init__(self, environment, transactionType, vaults=[], maturities=[], accounts=brownie.accounts, **kwargs):
        self.environment = environment
        self.environment.vaults = vaults
        self.accounts = accounts
        # A single string or array of strings signifying the transfer group expected
        self.transactionType = transactionType
        self.txnArgs = kwargs
        self.maturities = maturities

    def __enter__(self):
        self.snapshot = get_snapshot(self.environment, self.accounts, additionalMaturities=self.maturities)
        self.context = {}
        
        return self.context

    def hasTransactionType(self, eventStore):
        didMatch = [t for t in eventStore['transactionTypes'] if t['transactionType'] == self.transactionType]
        assert len(didMatch) > 0
        t = didMatch[0]
        for key, value in self.txnArgs.items():
            if callable(value):
                assert value(t[key]), "callable did not match on {}".format(key)
            else:
                assert value == t[key], "transaction property {} did not match, {} != {}".format(key, value, t[key])


    def __exit__(self, *_):
        eventStore = processTxn(self.environment, self.context['txn'])
        
        # Asserts that the snapshot balances equal the actual balance changes
        compare_snapshot(self.environment, self.snapshot, eventStore['transfers'], self.context)

        # Asserts that the transaction type is valid
        self.hasTransactionType(eventStore)


