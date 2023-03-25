import json
import pytest
import eth_abi
from brownie import accounts, Contract, interface
from brownie.network import Chain
from brownie.convert.datatypes import Wei
from tests.helpers import get_balance_action
from scripts.deployment import deployArtifact
from scripts.mainnet.V3Environment import V3Environment

chain = Chain()

@pytest.fixture(scope="module", autouse=True)
def v3env(accounts):
    return V3Environment(accounts)

@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

def test_upgrade_view_methods(v3env):
    globalMethods = [
        'getTreasuryManager',
        'getMaxCurrencyId',
        'getNoteToken',
        'owner'
    ]

    perCurrencyMethods = [
        'getReserveBuffer',
        'getCurrency',
        'getCashGroup',
        # TODO: fix these so they return similar values
        # 'getCurrencyAndRates',
        # 'getCashGroupAndAssetRate',
        'nTokenAddress',
        'getSecondaryIncentiveRewarder',
    ]

    # Anchor rates are deprecated
    #    'getInitializationParameters',
    # There are slight changes in lastImpliedRate...
    #    'getActiveMarkets',  

    globalDataBefore = {
        m: getattr(v3env.notional, m)() for m in globalMethods
    }

    perCurrencyDataBefore = {
        m: [
            getattr(v3env.notional, m)(i)
            for i in range(1, globalDataBefore['getMaxCurrencyId'] + 1)
        ]
        for m in perCurrencyMethods
    }

    nTokenBefore = [
        v3env.notional.getNTokenAccount(perCurrencyDataBefore['nTokenAddress'][i])
        for i in range(0, globalDataBefore['getMaxCurrencyId'])
    ]

    v3env.upgradeToV3()

    globalDataAfter = {
        m: getattr(v3env.notional, m)() for m in globalMethods
    }

    perCurrencyDataAfter = {
        m: [
            getattr(v3env.notional, m)(i)
            for i in range(1, globalDataBefore['getMaxCurrencyId'] + 1)
        ]
        for m in perCurrencyMethods
    }

    nTokenAfter = [
        v3env.notional.getNTokenAccount(perCurrencyDataBefore['nTokenAddress'][i])
        for i in range(0, globalDataBefore['getMaxCurrencyId'])
    ]

    assert globalDataBefore == globalDataAfter
    assert nTokenBefore == nTokenAfter
    assert perCurrencyDataBefore == perCurrencyDataAfter

def test_wrapped_fcash_actions(v3env):
    v3env.upgradeToV3()
    weth = interface.IERC20("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
    # test wrapped fcash, lend underlying, lend asset, deposit, withdraw, redeem etc.
    impl = deployArtifact("scripts/artifacts/wfCashERC4626.json", [
        v3env.notional.address,
        weth.address
    ], v3env.deployer, "wfCashERC4626")
    beacon = deployArtifact(
        "scripts/artifacts/nUpgradeableBeacon.json", 
        [impl.address], 
        v3env.deployer, "nUpgradeableBeacon"
    )
    factory = deployArtifact(
        "scripts/artifacts/WrappedfCashFactory.json", 
        [beacon.address], 
        v3env.deployer, 
        "WrappedfCashFactory"
    )
    markets = v3env.notional.getActiveMarkets(1)
    txn = factory.deployWrapper(1, markets[0][1])
    with open("abi/wfCashERC4626.json", "r") as f:
        abi = json.load(f)
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], abi)
    wethWhale = accounts.at("0xeD1840223484483C0cb050E6fC344d1eBF0778a9", force=True)
    weth.approve(wrapper.address, 2**256-1, {"from": wethWhale})
    wethBefore = weth.balanceOf(wethWhale)
    
    wrapper.mintViaUnderlying(1e18, 1e8, wethWhale, 0, {"from": wethWhale})
    assert pytest.approx(wethBefore - weth.balanceOf(wethWhale), rel=1e-2) == 1e18
    assert wrapper.balanceOf(wethWhale) == 1e8

    wrapper.redeemToUnderlying(1e8, wethWhale, 0, {"from": wethWhale})
    assert wrapper.balanceOf(wethWhale) == 0
    assert pytest.approx(weth.balanceOf(wethWhale), rel=1e-2) == wethBefore

@pytest.mark.skip
def test_vault_exit_blockheight_migration(v3env):
    # Check that existing vault accounts can exit
    existingVaultAccount = "0x70fce97d671e81080ca3ab4cc7a59aac2e117137"
    wstETH_ETH = "0xf049b944ec83abb50020774d48a8cf40790996e6"
    acct = v3env.notional.getVaultAccount(existingVaultAccount, wstETH_ETH)
    redeemParams = eth_abi.encode(
        ['uint256', 'uint256', 'bytes'],
        [0, 0, eth_abi.encode([
            'uint16',
            'uint8',
            'uint32',
            'bool',
            'bytes'
        ], [
            5, # curve
            0, # exact in single
            Wei(0.005e8), # oracle slippage
            True, # trade unwrapped
            bytes(), # params
        ])]
    )

    # TODO: this reverts inside the aura helper, but past the exit restriction
    v3env.notional.exitVault(
        existingVaultAccount,
        wstETH_ETH,
        existingVaultAccount,
        acct['vaultShares'],
        -acct['accountDebtUnderlying'],
        0, # min lend rate
        redeemParams,
        {"from": existingVaultAccount }
    )

@pytest.mark.skip
def test_vault_exit_blockheight_migration(v3env, accounts):
    # enter before upgrade, exit after as existing vault
    wstETH_ETH = "0xf049b944ec83abb50020774d48a8cf40790996e6"

    txn = v3env.notional.enterVault(
        accounts[0],
        wstETH_ETH,
        25e18,
        v3env.notional.getActiveMarkets(1)[0][1],
        100e8,
        0,
        eth_abi.encode(['uint256', 'bytes'], [0, bytes()]),
        {"from": accounts[0], "value": 25e18}
    )

    acct = v3env.notional.getVaultAccount(accounts[0], wstETH_ETH)
    # This is the original block time
    assert acct['lastUpdateBlockTime'] == txn.block_number

    v3env.upgradeToV3()

    redeemParams = eth_abi.encode(
        ['uint256', 'uint256', 'bytes'],
        [0, 0, eth_abi.encode([
            'uint16',
            'uint8',
            'uint32',
            'bool',
            'bytes'
        ], [
            5, # curve
            0, # exact in single
            Wei(0.005e8), # oracle slippage
            True, # trade unwrapped
            bytes(), # params
        ])]
    )

    # Check that the account can now exit (immediately)
    v3env.notional.exitVault(
        accounts[0],
        wstETH_ETH,
        accounts[0],
        acct['vaultShares'],
        -acct['accountDebtUnderlying'],
        0, # min lend rate
        redeemParams,
        {"from": accounts[0] }
    )

def test_withdraws_and_redeem_ctoken(v3env, accounts):
    # Existing whale account, has nETH, nDAI, nUSDC
    whale = accounts.at("0x741aa7cfb2c7bf2a1e7d4da2e3df6a56ca4131f3", force=True)

    # This is the amount they can redeem and withdraw prior to upgrade
    nETH_balance = v3env.notional.getAccountBalance(1, whale)['nTokenBalance']
    nDAI_balance = v3env.notional.getAccountBalance(2, whale)['nTokenBalance']
    nUSDC_balance = v3env.notional.getAccountBalance(3, whale)['nTokenBalance']

    ethBefore = whale.balance()
    daiBefore = v3env.tokens['DAI'].balanceOf(whale)
    usdcBefore = v3env.tokens['USDC'].balanceOf(whale)

    v3env.notional.batchBalanceAction(whale, [
        get_balance_action(1, 'RedeemNToken', depositActionAmount=nETH_balance, withdrawEntireCashBalance=True, redeemToUnderlying=True),
        get_balance_action(2, 'RedeemNToken', depositActionAmount=nDAI_balance, withdrawEntireCashBalance=True, redeemToUnderlying=True),
        get_balance_action(3, 'RedeemNToken', depositActionAmount=nUSDC_balance, withdrawEntireCashBalance=True, redeemToUnderlying=True),
    ], {"from": whale})

    ethRedeemBefore = whale.balance() - ethBefore
    daiRedeemBefore = v3env.tokens['DAI'].balanceOf(whale) - daiBefore
    usdcRedeemBefore = v3env.tokens['USDC'].balanceOf(whale) - usdcBefore

    # Undo the redemption and then upgrade to v3
    chain.undo()

    v3env.upgradeToV3()

    # Matches what they can redeem and withdraw post upgrade
    ethBefore = whale.balance()
    daiBefore = v3env.tokens['DAI'].balanceOf(whale)
    usdcBefore = v3env.tokens['USDC'].balanceOf(whale)

    # TODO: this is reverting inside
    v3env.notional.batchBalanceAction(whale, [
        get_balance_action(1, 'RedeemNToken', depositActionAmount=nETH_balance, withdrawEntireCashBalance=True, redeemToUnderlying=True),
        get_balance_action(2, 'RedeemNToken', depositActionAmount=nDAI_balance, withdrawEntireCashBalance=True, redeemToUnderlying=True),
        get_balance_action(3, 'RedeemNToken', depositActionAmount=nUSDC_balance, withdrawEntireCashBalance=True, redeemToUnderlying=True),
    ], {"from": whale})

    ethRedeemAfter = whale.balance() - ethBefore
    daiRedeemAfter = v3env.tokens['DAI'].balanceOf(whale) - daiBefore
    usdcRedeemAfter = v3env.tokens['USDC'].balanceOf(whale) - usdcBefore

    assert ethRedeemBefore == ethRedeemAfter
    assert daiRedeemBefore == daiRedeemAfter
    assert usdcRedeemBefore == usdcRedeemAfter

def test_non_mintable_upgrade_and_listing(v3env):
    # list wstETH prior to upgrade and provide some liquidity, etc.

    # upgrade to v3

    # check that deposits, withdraws, trading all work properly

    pass

