import eth_abi
from brownie import (
    accounts,
    MockWETH,
    NotionalV2FlashLiquidator,
    NotionalV2ManualLiquidator,
    MockAaveFlashLender,
    MockUniV3SwapRouter,
    UpgradeableBeacon,
    nBeaconProxy,
    MockManualLiquidator
)
from brownie.convert.datatypes import HexString
from brownie.project import ContractsVProject
from brownie.network.contract import Contract
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, nTokenDefaults
from scripts.deployment import TestEnvironment
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import get_balance_action, get_balance_trade_action, get_tref

chain = Chain()
CollateralCurrency_NoTransferFee_Withdraw = 1
CollateralCurrency_NoTransferFee_NoWithdraw = 9
CrossCurrencyfCash_NoTransferFee_Withdraw = 3
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

    pathCalldata = eth_abi.encode_abi(
        ["address", "uint24", "address"], 
        [env.weth.address, 3000, env.token["DAI"].address],
    )
    tradeCalldata = eth_abi.encode_abi(
        ["bytes", "uint256"],
        [pathCalldata, chain.time() + 20000],
    )

    calldata = eth_abi.encode_abi(
        [
            "uint8",
            "address",
            "uint16",
            "address",
            "uint16",
            "address",
            "address",
            "uint128",
            "uint96",
            "bytes",
        ],
        [
            CollateralCurrency_NoTransferFee_Withdraw,
            accounts[1].address,
            2,
            env.token['DAI'].address,
            1,
            env.cToken['ETH'].address,
            env.weth.address,
            0,
            0,
            tradeCalldata,
        ],
    )

    print(env.notional.getFreeCollateral(accounts[1]))
    env.flashLender.flashLoan(
        env.flashLiquidator.address,
        [env.token["DAI"].address],
        [120e18],
        [0],
        env.flashLiquidator.address,
        calldata,
        0,
        {"from": accounts[0]},
    )
    print(env.notional.getFreeCollateral(accounts[1]))

def _enable_cash_group(currencyId, env, accounts, initialCash=50000000e8):
    env.notional.updateDepositParameters(currencyId, *(nTokenDefaults["Deposit"]))
    env.notional.updateInitializationParameters(currencyId, *(nTokenDefaults["Initialization"]))
    env.notional.updateTokenCollateralParameters(currencyId, *(nTokenDefaults["Collateral"]))
    env.notional.updateIncentiveEmissionRate(currencyId, CurrencyDefaults["incentiveEmissionRate"])

    env.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(
                currencyId, "DepositAssetAndMintNToken", depositActionAmount=initialCash
            )
        ],
        {"from": accounts[0]},
    )
    env.notional.initializeMarkets(currencyId, True)

def fcashLiquidateSetup(env):
    cToken = env.cToken["ETH"]
    cToken.mint({"from": accounts[0], "value": 10000e18})
    cToken.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})

    _enable_cash_group(1, env, accounts, initialCash=40000e8)
    cashGroup = list(env.notional.getCashGroup(2))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[9] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[10] = CurrencyDefaults["rateScalar"][0:3]
    env.notional.updateCashGroup(2, cashGroup)

    env.notional.updateDepositParameters(2, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9])

    env.notional.updateInitializationParameters(
        2, [0.01e9, 0.021e9, 0.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    env.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(1, "DepositUnderlyingAndMintNToken", depositActionAmount=5e18),
            get_balance_action(2, "DepositAssetAndMintNToken", depositActionAmount=5000e8),
        ],
        {"from": accounts[0], "value": 5e18},
    )

    env.notional.initializeMarkets(2, True)

    env.notional.batchBalanceAction(
        accounts[0],
        [
            get_balance_action(1, "DepositUnderlyingAndMintNToken", depositActionAmount=5e18),
            get_balance_action(2, "DepositAssetAndMintNToken", depositActionAmount=5000000e8),
        ],
        {"from": accounts[0], "value": 5e18},
    )

def crossCurrencyLiquidate(env):
    fcashLiquidateSetup(env)
    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    collateral = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 1e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 1e8, "minSlippage": 0},
        ],
        depositActionAmount=2e18,
    )
    env.notional.batchBalanceAndTradeAction(
        accounts[1], [collateral, borrowAction], {"from": accounts[1], "value": 2e18})

    # Drop ETH price
    env.ethOracle["DAI"].setAnswer(0.017e18)

    pathCalldata = eth_abi.encode_abi(
        ["address", "uint24", "address"], 
        [env.weth.address, 3000, env.token["DAI"].address],
    )
    tradeCalldata = eth_abi.encode_abi(
        ["bytes", "uint256"],
        [pathCalldata, chain.time() + 20000],
    )

    liquidatedPortfolioBefore = env.notional.getAccountPortfolio(accounts[1])
    maturities = [asset[1] for asset in liquidatedPortfolioBefore]
    print(maturities)
    maturities.sort(reverse=True)
    print(maturities)
    limits = [0 for mat in maturities]

    print(limits)

    calldata = eth_abi.encode_abi(
        [
            "uint8",
            "address",
            "uint16",
            "address",
            "uint16",
            "address",
            "address",
            "uint256[]",
            "uint256[]",
            "bytes",
        ],
        [
            CrossCurrencyfCash_NoTransferFee_Withdraw,
            accounts[1].address,
            2,
            env.token['DAI'].address,
            1,
            env.cToken['ETH'].address,
            env.weth.address,
            maturities,
            limits,
            tradeCalldata,
        ],
    )

    print(env.notional.getFreeCollateral(accounts[1]))
    env.flashLender.flashLoan(
        env.flashLiquidator.address,
        [env.token["DAI"].address],
        [120e18],
        [0],
        env.flashLiquidator.address,
        calldata,
        0,
        {"from": accounts[0]},
    )
    print(env.notional.getFreeCollateral(accounts[1]))

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

def setFlashLiquidatorAppovals(env, deployer):
    env.flashLiquidator.setCTokenAddress(env.cToken["DAI"].address, {"from": deployer})
    env.flashLiquidator.setCTokenAddress(env.cToken["USDC"].address, {"from": deployer})
    env.flashLiquidator.setCTokenAddress(env.cToken["WBTC"].address, {"from": deployer})
    env.flashLiquidator.approveToken(env.cToken["ETH"].address, env.notional.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.weth.address, env.flashLender.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.weth.address, env.swapRouter.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.token["DAI"].address, env.flashLender.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.token["DAI"].address, env.swapRouter.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.token["USDC"].address, env.flashLender.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.token["USDC"].address, env.swapRouter.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.token["WBTC"].address, env.flashLender.address, {"from": deployer})
    env.flashLiquidator.approveToken(env.token["WBTC"].address, env.swapRouter.address, {"from": deployer})

def setManualLiquidatorApprovals(env, liquidator, deployer):
    liquidator.enableCToken(env.cToken["DAI"].address, {"from": deployer})
    liquidator.enableCToken(env.cToken["USDC"].address, {"from": deployer})
    liquidator.enableCToken(env.cToken["WBTC"].address, {"from": deployer})
    liquidator.approveToken(env.cToken["ETH"].address, env.notional.address, {"from": deployer})
    liquidator.approveToken(env.weth.address, env.swapRouter.address, {"from": deployer})
    liquidator.approveToken(env.token["DAI"].address, env.swapRouter.address, {"from": deployer})
    liquidator.approveToken(env.token["USDC"].address, env.swapRouter.address, {"from": deployer})
    liquidator.approveToken(env.token["WBTC"].address, env.swapRouter.address, {"from": deployer})

def deployManualLiquidator(env, currencyId, deployer):
    initData = env.manualLiquidator.initialize.encode_input(currencyId)
    proxy = nBeaconProxy.deploy(env.manualLiquidatorBeacon.address, initData, {"from": deployer})
    abi = ContractsVProject._build.get("NotionalV2ManualLiquidator")["abi"]
    liquidator = Contract.from_abi(
        "NotionalV2ManualLiquidator", proxy.address, abi=abi, owner=deployer
    )
    setManualLiquidatorApprovals(env, liquidator, deployer)
    return liquidator

def main():
    env = environment(accounts)
    deployer = accounts[0]

    # Create exchange
    env.weth = MockWETH.deploy({"from": deployer})
    env.swapRouter = MockUniV3SwapRouter.deploy(env.weth, deployer, {"from": deployer})
    env.weth.deposit({"from": deployer, "value": 50e18})
    env.weth.transfer(env.swapRouter.address, 50e18, {"from": deployer})

    env.token["DAI"].transfer(env.swapRouter.address, 1000e18, {"from": deployer})
    env.token["USDT"].transfer(env.swapRouter.address, 1000e6, {"from": deployer})
    
    # Create flash lender
    env.flashLender = MockAaveFlashLender.deploy(env.weth, deployer, {"from": deployer})
    # Give flash lender assets
    env.weth.deposit({"from": deployer, "value": 5000e18})
    env.weth.transfer(env.flashLender.address, 100e18, {"from": deployer})
    env.token["DAI"].transfer(env.flashLender.address, 100000e18, {"from": deployer})
    env.token["USDT"].transfer(env.flashLender.address, 100000e6, {"from": deployer})    

    # Deploy flash liquidator
    env.flashLiquidator = NotionalV2FlashLiquidator.deploy(
        env.notional.address,
        env.flashLender.address,
        env.weth,
        env.cToken["ETH"].address,
        deployer.address,
        env.swapRouter.address,        
        {"from": deployer})

    setFlashLiquidatorAppovals(env, deployer)

    # Deploy manual liquidator implementation
    env.manualLiquidator = NotionalV2ManualLiquidator.deploy(
        env.notional.address,
        env.weth,
        env.cToken["ETH"].address,
        env.swapRouter.address,
        env.noteERC20Proxy.address,
        {"from": deployer})

    env.manualLiquidatorMock = MockManualLiquidator.deploy({"from": deployer})
        
    # Deploy upgradable beacon
    env.manualLiquidatorBeacon = UpgradeableBeacon.deploy(env.manualLiquidator.address, {"from": deployer})

    env.manualLiquidatorETH = deployManualLiquidator(env, 1, deployer)
    env.manualLiquidatorDAI = deployManualLiquidator(env, 2, deployer)
    env.manualLiquidatorUSDC = deployManualLiquidator(env, 3, deployer)
    env.manualLiquidatorWBTC = deployManualLiquidator(env, 4, deployer)

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

    env.cToken["DAI"].transfer(env.manualLiquidatorDAI.address, 5000e8, {"from": deployer})

    chain.snapshot()
    collateralLiquidate(env)
    chain.revert()
    crossCurrencyLiquidate(env)
    
