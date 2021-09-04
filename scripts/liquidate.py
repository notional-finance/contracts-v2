import eth_abi
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
CollateralCurrency_NoTransferFee = 1
zeroAddress = HexString(0, "bytes20")

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

    env.ethOracle["DAI"].setAnswer(0.017e18)

    tradeCalldata = eth_abi.encode_abi(
        [
            "uint24", 
            "uint256", 
            "uint160"
        ],
        [
            3000,
            chain.time() + 20000,
            0
        ]
    )

    calldata = eth_abi.encode_abi(
        [
            "uint8",
            "address",
            "uint256",
            "uint256",
            "uint128",
            "uint96",
            "bytes",
        ],
        [
            CollateralCurrency_NoTransferFee,
            accounts[1].address,
            2,
            1,
            0,
            0,
            tradeCalldata,
        ],
    )

    env.flashLender.flashLoan(
        env.flashLiquidator.address,
        [env.token["DAI"].address],
        [100e18],
        [0],
        env.flashLiquidator.address,
        calldata,
        0,
        {"from": accounts[0]},
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

    # Create exchange
    env.weth = MockWETH.deploy({"from": deployer})
    env.swapRouter = MockUniV3SwapRouter.deploy({"from": deployer})
    env.weth.deposit({"from": accounts[0], "value": 50e18})
    env.weth.transfer(env.swapRouter.address, 50e18, {"from": accounts[0]})

    env.token["DAI"].transfer(env.swapRouter.address, 1000e18, {"from": accounts[0]})
    env.token["USDT"].transfer(env.swapRouter.address, 1000e6, {"from": accounts[0]})
    
    # Create flash lender
    env.flashLender = MockAaveFlashLender.deploy({"from": deployer})
    # Give flash lender assets
    env.weth.deposit({"from": accounts[0], "value": 5000e18})
    env.weth.transfer(env.flashLender.address, 100e18, {"from": accounts[0]})
    env.token["DAI"].transfer(env.flashLender.address, 100000e18, {"from": accounts[0]})
    env.token["USDT"].transfer(env.flashLender.address, 100000e6, {"from": accounts[0]})    

    env.flashLiquidator = NotionalV2UniV3FlashLiquidator.deploy(
        env.swapRouter.address,
        env.notional.address,
        env.flashLender.address,
        env.flashLender.address,
        env.weth,
        env.cToken["ETH"].address,
        {"from": deployer}
    )

    env.flashLiquidator.setCTokenAddress(env.cToken["DAI"].address, {"from": accounts[0]})
    env.flashLiquidator.setCTokenAddress(env.cToken["USDT"].address, {"from": accounts[0]})
    env.flashLiquidator.approveToken(env.cToken["ETH"].address, env.notional.address, {"from": accounts[0]})
    env.flashLiquidator.approveToken(env.weth.address, env.flashLender.address, {"from": accounts[0]})
    env.flashLiquidator.approveToken(env.weth.address, env.swapRouter.address, {"from": accounts[0]})

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
