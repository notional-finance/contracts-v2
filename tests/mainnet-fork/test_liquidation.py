import pytest
import brownie
import eth_abi
import math
from brownie import Wei, ZERO_ADDRESS, accounts, Contract, interface, FlashLiquidator
from brownie.network.state import Chain
from brownie.convert import to_bytes
from scripts.mainnet.V3Environment import V3Environment
from tests.helpers import get_balance_action, get_balance_trade_action

chain = Chain()

@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()
    
@pytest.fixture(scope="module", autouse=True)
def v3env(accounts):
    return V3Environment(accounts)

def underlyingPrecision(env, currencyId):
    if (currencyId == 1):
        return 1e18
    else:
        return env.notional.getCurrency(currencyId)[1][2]

def pathCalldataExactOut(fromAddr, toAddr):
    if fromAddr == ZERO_ADDRESS:
        fromAddr = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    if toAddr == ZERO_ADDRESS:
        toAddr = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    packedEncoder = eth_abi.codec.ABIEncoder(eth_abi.registry.registry_packed)
    return packedEncoder.encode_abi(
        ["address", "uint24", "address"], 
        [toAddr, 3000, fromAddr]
    )

def collateralCalldata(
    env,
    localCurrency, 
    account, 
    collateralCurrency, 
    amount, 
    liquidator
):
    router = interface.ISwapRouter("0xE592427A0AEce92De3Edee1F18E0157C05861564")
    localUnderlying = env.notional.getCurrencyAndRates(localCurrency)["underlyingToken"][0]
    collateralUnderlying = env.notional.getCurrencyAndRates(collateralCurrency)["underlyingToken"][0]
    liqCalldata = eth_abi.encode_abi(
        ['(address,uint16,uint16,address,uint128,uint96,(address,bytes))'],
        [[
            account, 
            localCurrency, 
            collateralCurrency,  
            collateralUnderlying,
            0,
            0,
            [
                router.address,
                to_bytes(router.exactOutput.encode_input([
                    pathCalldataExactOut(collateralUnderlying, localUnderlying),
                    liquidator,
                    chain.time() + 20000,
                    math.floor(amount * 1.01),
                    Wei(2**256-1)
                ]), "bytes")
            ]
        ]]
    )
    return eth_abi.encode_abi(
        ['(uint8,bool,bool,bytes)'],
        [[1, False, False, liqCalldata]]
    )

def test_eth_liquidation(v3env):
    v3env.upgradeToV3()
    daiWhale = accounts.at("0x604981db0C06Ea1b37495265EDa4619c8Eb95A3D", force=True)
    v3env.tokens["DAI"].approve(v3env.notional, 2**256-1, {"from": daiWhale})
    collateral = get_balance_trade_action(2, "DepositUnderlying", [], depositActionAmount=10_000e18)
    v3env.notional.batchBalanceAndTradeAction(
        daiWhale, [collateral], {"from": daiWhale}
    )

    borrow = get_balance_trade_action(
        1,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 4e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    v3env.notional.batchBalanceAndTradeAction(
        daiWhale, [borrow], {"from": daiWhale}
    )

    v3env.notional.updateETHRate(
        2, 
        "0x6085B0a8f4c7ffA2E8CA578037792D6535d1E29B", 
        False, 
        130, 
        75, 
        120, 
        {"from": v3env.notional.owner()}
    )

    liquidator = FlashLiquidator.deploy(
        v3env.notional,
        "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9", # Aave 
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH
        "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0", # wstETH
        v3env.deployer,
        "0xE592427A0AEce92De3Edee1F18E0157C05861564",  # UniV3,
        "0xE592427A0AEce92De3Edee1F18E0157C05861564",  # UniV3,
        {"from": v3env.deployer}
    )
    liquidator.enableCurrencies([1,2,3,4], {"from": v3env.deployer})

    localCurrencyRequired = v3env.notional.calculateCollateralCurrencyLiquidation.call(
        daiWhale,
        1, 
        2, 
        0, 
        0, 
        {"from": v3env.deployer} 
    )[0]
    loanAmount = v3env.notional.convertCashBalanceToExternal(1, localCurrencyRequired, True) * 1.2

    liquidator.flashLoan(
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", 
        loanAmount, 
        collateralCalldata(
            v3env, 
            1, 
            daiWhale.address, 
            2, 
            v3env.notional.convertCashBalanceToExternal(1, localCurrencyRequired, True), 
            liquidator
        ), "0x6b175474e89094c44da98b954eedeac495271d0f"
    )
