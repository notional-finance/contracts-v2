
from brownie import (
    accounts,
    MockWETH,
    NotionalV2UniV3FlashLiquidator,
    MockAaveFlashLender,
    MockUniV3SwapRouter
)
from brownie.convert.datatypes import HexString
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, nTokenDefaults
from scripts.deployment import TestEnvironment
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import get_balance_action, get_balance_trade_action, get_tref

chain = Chain()

def environment(accounts):
    return TestEnvironment(accounts[0])

def cashLiquidateSetup(env):
    env.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(2, "DepositAssetAndMintNToken", depositActionAmount=5000000e8),
            get_balance_action(4, "DepositAssetAndMintNToken", depositActionAmount=5000000e8),
        ],
        {"from": accounts[0]},
    )
    env.notional.initializeMarkets(2, True)
    env.notional.initializeMarkets(4, True)

def collateralLiquidate(env):
    cashLiquidateSetup(env)
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    ethCollateral = get_balance_trade_action(1, "DepositUnderlying", [], depositActionAmount=3e18)
    env.notional.batchBalanceAndTradeAction(
        accounts[1], [ethCollateral, borrowAction], {"from": accounts[1], "value": 3e18}
    )

DEPOSIT_PARAMETERS = {
    2: [[int(0.4e8), int(0.6e8)], [int(0.8e9)] * 2],
    3: [[int(0.4e8), int(0.4e8), int(0.2e8)], [int(0.8e9)] * 3],
    4: [[int(0.4e8), int(0.2e8), int(0.2e8), int(0.2e8)], [int(0.8e9)] * 4],
    5: [[int(0.2e8), int(0.2e8), int(0.2e8), int(0.2e8), int(0.2e8)], [int(0.8e9)] * 5],
    6: [[int(0.2e8), int(0.2e8), int(0.2e8), int(0.2e8), int(0.1e8), int(0.1e8)], [int(0.8e9)] * 6],
    7: [
        [int(0.2e8), int(0.2e8), int(0.2e8), int(0.2e8), int(0.1e8), int(0.05e8), int(0.05e8)],
        [int(0.8e9)] * 7,
    ],
}

INIT_PARAMETERS = {
    2: [[int(0.01e9)] * 2, [int(0.5e9)] * 2],
    3: [[int(0.01e9)] * 3, [int(0.5e9)] * 3],
    4: [[int(0.01e9)] * 4, [int(0.5e9)] * 4],
    5: [[int(0.01e9)] * 5, [int(0.5e9)] * 5],
    6: [[int(0.01e9)] * 6, [int(0.5e9)] * 6],
    7: [[int(0.01e9)] * 7, [int(0.5e9)] * 7],
}

def main():
    env = environment(accounts)
    deployer = accounts[0]
    zeroAddress = HexString(0, "bytes20")

    env.uniV3Router = MockUniV3SwapRouter.deploy({"from": deployer})
    env.weth = MockWETH.deploy({"from": deployer})
    
    # Create flash lender
    env.flashLender = MockAaveFlashLender.deploy({"from": deployer})
    # Give flash lender assets
    env.weth.deposit({"from": accounts[0], "value": 5000e18})
    env.weth.transfer(env.flashLender.address, 100e18, {"from": accounts[0]})
    env.token["DAI"].transfer(env.flashLender.address, 100000e18, {"from": accounts[0]})
    env.token["USDT"].transfer(env.flashLender.address, 100000e6, {"from": accounts[0]})    

    env.flashLiquidator = NotionalV2UniV3FlashLiquidator.deploy(
        env.uniV3Router.address,
        env.notional.address,
        env.flashLender.address,
        zeroAddress,
        env.weth,
        env.cToken["ETH"].address,
        {"from": deployer}
    )

    # Set time
    blockTime = chain.time()
    newTime = get_tref(blockTime) + SECONDS_IN_QUARTER + 1
    chain.mine(1, timestamp=newTime)

    cToken = env.cToken["DAI"]
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["DAI"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(100000000e18, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    env.token["DAI"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    env.token["DAI"].transfer(accounts[1], 1000e18, {"from": accounts[0]})
    cToken.transfer(accounts[1], 500000e8, {"from": accounts[0]})

    env.enableCurrency("DAI", CurrencyDefaults)
    currencyId = 2
    env.notional.updateDepositParameters(currencyId, *(nTokenDefaults["Deposit"]))
    env.notional.updateInitializationParameters(currencyId, *(nTokenDefaults["Initialization"]))
    env.notional.updateTokenCollateralParameters(currencyId, *(nTokenDefaults["Collateral"]))
    env.notional.updateIncentiveEmissionRate(currencyId, CurrencyDefaults["incentiveEmissionRate"])

    cToken = env.cToken["USDT"]
    env.token["USDT"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["USDT"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(100000000e18, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.enableCurrency("USDT", CurrencyDefaults)

    cToken = env.cToken["USDC"]
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.token["USDC"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(100000000e6, {"from": accounts[0]})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    env.token["USDC"].approve(env.notional.address, 2 ** 255, {"from": accounts[1]})
    env.token["USDC"].transfer(accounts[1], 10000e6, {"from": accounts[0]})
    cToken.transfer(accounts[1], 500000e8, {"from": accounts[0]})
    env.enableCurrency("USDC", CurrencyDefaults)

    currencyId = 4
    # TODO: what if this isnt initialized?
    env.notional.updateDepositParameters(currencyId, *(nTokenDefaults["Deposit"]))
    env.notional.updateInitializationParameters(currencyId, *(nTokenDefaults["Initialization"]))
    env.notional.updateTokenCollateralParameters(currencyId, *(nTokenDefaults["Collateral"]))
    env.notional.updateIncentiveEmissionRate(currencyId, CurrencyDefaults["incentiveEmissionRate"])

    chain.snapshot()

    collateralLiquidate(env)
