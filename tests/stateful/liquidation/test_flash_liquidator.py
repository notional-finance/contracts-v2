import eth_abi
import pytest
from brownie import MockExchange, web3
from brownie.convert import to_bytes
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from scripts.config import CurrencyDefaults, nTokenDefaults
from tests.constants import SECONDS_IN_QUARTER
from tests.helpers import get_balance_action, get_balance_trade_action, initialize_environment

chain = Chain()
LocalCurrency_NoTransferFee = 0
CollateralCurrency_NoTransferFee = 1
LocalfCash_NoTransferFee = 2
CrossCurrencyfCash_NoTransferFee = 3
LocalCurrency_WithTransferFee = 4
CollateralCurrency_WithTransferFee = 5
LocalfCash_WithTransferFee = 6
CrossCurrencyfCash_WithTransferFee = 7


def transferTokens(environment, accounts):
    account = accounts[2]
    environment.cToken["ETH"].transfer(account, 100000e8, {"from": accounts[0]})
    environment.cToken["ETH"].approve(environment.notional.address, 2 ** 255, {"from": account})
    environment.cToken["DAI"].transfer(account, 100000e8, {"from": accounts[0]})
    environment.cToken["DAI"].approve(environment.notional.address, 2 ** 255, {"from": account})
    environment.cToken["USDT"].transfer(account, 100000e8, {"from": accounts[0]})
    environment.cToken["USDT"].approve(environment.notional.address, 2 ** 255, {"from": account})


@pytest.fixture(scope="module", autouse=True)
def weth(MockWETH, accounts):
    return MockWETH.deploy({"from": accounts[9]})


@pytest.fixture(scope="module", autouse=True)
def mockExchange(MockExchange, weth, env, accounts):
    m = MockExchange.deploy({"from": accounts[9]})
    weth.deposit({"from": accounts[9], "value": 5000e18})
    weth.transfer(m.address, 100e18, {"from": accounts[9]})

    env.token["DAI"].transfer(m.address, 100000e18, {"from": accounts[0]})
    env.token["USDT"].transfer(m.address, 100000e6, {"from": accounts[0]})

    return m


@pytest.fixture(scope="module", autouse=True)
def flashLiquidator(NotionalV2FlashLiquidator, env, mockFlashLender, weth, accounts):
    liquidator = NotionalV2FlashLiquidator.deploy(
        env.notional.address,
        mockFlashLender.address,
        mockFlashLender.address,
        weth.address,
        env.cToken["ETH"].address,
        {"from": accounts[1]},
    )

    liquidator.setCTokenAddress(env.cToken["DAI"].address, {"from": accounts[1]})
    liquidator.setCTokenAddress(env.cToken["USDT"].address, {"from": accounts[1]})
    liquidator.approveToken(env.cToken["ETH"].address, env.notional.address, {"from": accounts[1]})
    liquidator.approveToken(weth.address, mockFlashLender.address, {"from": accounts[1]})

    return liquidator


@pytest.fixture(scope="module", autouse=True)
def mockFlashLender(MockFlashLender, weth, env, accounts):
    mockLender = MockFlashLender.deploy({"from": accounts[9]})
    weth.deposit({"from": accounts[0], "value": 5000e18})

    weth.transfer(mockLender.address, 100e18, {"from": accounts[0]})
    env.token["DAI"].transfer(mockLender.address, 100000e18, {"from": accounts[0]})
    env.token["USDT"].transfer(mockLender.address, 100000e6, {"from": accounts[0]})

    return mockLender


@pytest.fixture(scope="module", autouse=True)
def env(accounts):
    environment = initialize_environment(accounts)
    environment.enableCurrency("USDT", CurrencyDefaults)
    cashGroup = list(environment.notional.getCashGroup(2))
    # Enable the one year market
    cashGroup[0] = 3
    cashGroup[9] = CurrencyDefaults["tokenHaircut"][0:3]
    cashGroup[10] = CurrencyDefaults["rateScalar"][0:3]

    environment.notional.updateCashGroup(2, cashGroup)
    environment.notional.updateDepositParameters(2, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9])
    environment.notional.updateInitializationParameters(
        2, [1.01e9, 1.021e9, 1.07e9], [0.5e9, 0.5e9, 0.5e9]
    )

    blockTime = chain.time()
    chain.mine(1, timestamp=(blockTime + SECONDS_IN_QUARTER))

    environment.notional.initializeMarkets(1, False)
    environment.notional.initializeMarkets(2, False)
    cToken = environment.cToken["USDT"]
    environment.token["USDT"].approve(environment.notional.address, 2 ** 255, {"from": accounts[0]})
    environment.token["USDT"].approve(cToken.address, 2 ** 255, {"from": accounts[0]})
    cToken.mint(200000000e6, {"from": accounts[0]})
    cToken.approve(environment.notional.address, 2 ** 255, {"from": accounts[0]})

    environment.notional.updateCashGroup(5, cashGroup)
    environment.notional.updateDepositParameters(5, [0.4e8, 0.4e8, 0.2e8], [0.8e9, 0.8e9, 0.8e9])
    environment.notional.updateTokenCollateralParameters(5, *(nTokenDefaults["Collateral"]))
    environment.notional.updateInitializationParameters(
        5, [1.01e9, 1.021e9, 1.07e9], [0.5e9, 0.5e9, 0.5e9]
    )
    environment.notional.batchBalanceAction(
        accounts[0],
        [get_balance_action(5, "DepositAssetAndMintNToken", depositActionAmount=50000000e8)],
        {"from": accounts[0]},
    )
    environment.notional.initializeMarkets(5, True)

    transferTokens(environment, accounts)

    return environment


def setup_local_currency_liquidate(currencyId, env, account):
    collateral = get_balance_trade_action(
        currencyId,
        "DepositAssetAndMintNToken",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        depositActionAmount=5500e8,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )
    env.notional.batchBalanceAndTradeAction(account, [collateral], {"from": account})

    tokenDefaults = nTokenDefaults["Collateral"]
    tokenDefaults[1] = 85
    env.notional.updateTokenCollateralParameters(currencyId, *(tokenDefaults))


def test_local_currency_with_transfer_fee(env, weth, mockFlashLender, flashLiquidator, accounts):
    account = accounts[2]
    setup_local_currency_liquidate(5, env, account)

    params = eth_abi.encode_abi(
        ["uint8", "address", "uint256", "uint96"],
        [LocalCurrency_WithTransferFee, account.address, 5, 0],
    )

    mockFlashLender.executeFlashLoan(
        [env.token["USDT"].address], [70e6], flashLiquidator.address, params, {"from": accounts[1]}
    )


def test_local_currency_no_transfer_fee(env, weth, mockFlashLender, flashLiquidator, accounts):
    account = accounts[2]
    setup_local_currency_liquidate(2, env, account)

    params = eth_abi.encode_abi(
        ["uint8", "address", "uint256", "uint96"],
        [LocalCurrency_NoTransferFee, account.address, 2, 0],
    )

    mockFlashLender.executeFlashLoan(
        [env.token["DAI"].address], [100e18], flashLiquidator.address, params, {"from": accounts[1]}
    )


def test_local_currency_eth(env, weth, mockFlashLender, flashLiquidator, accounts):
    account = accounts[2]
    currencyId = 1
    collateral = get_balance_trade_action(
        currencyId,
        "DepositAssetAndMintNToken",
        [{"tradeActionType": "Borrow", "marketIndex": 2, "notional": 1e8, "maxSlippage": 0}],
        depositActionAmount=55e8,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=False,  # TODO: this is failing because there is nothing to redeem
    )
    env.notional.batchBalanceAndTradeAction(account, [collateral], {"from": account})

    tokenDefaults = nTokenDefaults["Collateral"]
    tokenDefaults[1] = 85
    env.notional.updateTokenCollateralParameters(currencyId, *(tokenDefaults))

    params = eth_abi.encode_abi(
        ["uint8", "address", "uint256", "uint96"],
        [LocalCurrency_NoTransferFee, account.address, 1, 0],
    )

    mockFlashLender.executeFlashLoan(
        [weth.address], [2e18], flashLiquidator.address, params, {"from": accounts[1]}
    )


# def test_collateral_currency_with_transfer_fee():


@pytest.mark.only
def test_collateral_currency_no_transfer_fee(
    env, weth, mockFlashLender, flashLiquidator, mockExchange, accounts
):
    account = accounts[2]
    collateral = get_balance_trade_action(
        1, "DepositUnderlyingAndMintNToken", [], depositActionAmount=1.5e18
    )

    borrowAction = get_balance_trade_action(
        2,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 3, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    env.notional.batchBalanceAndTradeAction(
        account, [collateral, borrowAction], {"from": account, "value": 1.5e18}
    )
    env.ethOracle["DAI"].setAnswer(0.013e18)
    mockExchange.setExchangeRate(100e18)

    # Static call to get predicted amount of collateral
    (
        _,
        collateralAsset,
        collateralNTokens,
    ) = env.notional.calculateCollateralCurrencyLiquidation.call(account.address, 2, 1, 0, 0)
    ethAmount = Wei((collateralAsset + collateralNTokens) / Wei(50e8) * Wei(1e18))

    tradeCalldata = to_bytes(
        web3.eth.contract(abi=MockExchange.abi).encodeABI(
            fn_name="exchange", args=[weth.address, env.token["DAI"].address, ethAmount]
        ),
        "bytes",
    )

    params = eth_abi.encode_abi(
        ["uint8", "address", "uint256", "uint256", "uint128", "uint96", "address", "uint256"],
        [CollateralCurrency_NoTransferFee, account.address, 2, 1, 0, 0, mockExchange.address, 0],
    )
    calldata = b"".join([params, tradeCalldata])

    flashLiquidator.approveToken(weth.address, mockExchange.address)
    mockFlashLender.executeFlashLoan(
        [env.token["DAI"].address],
        [100e18],
        flashLiquidator.address,
        calldata,
        {"from": accounts[1]},
    )


# def test_collateral_currency_eth():

# def test_local_fcash_with_transfer_fee():
# def test_local_fcash_no_transfer_fee():
# def t`est_local_fcash_eth():

# def test_cross_currency_fcash_with_transfer_fee():
# def test_cross_currency_fcash_no_transfer_fee():
# def test_cross_currency_fcash_eth():

# def test_local_ifcash_with_transfer_fee():
# def test_local_ifcash_no_transfer_fee():
# def test_local_ifcash_eth():

# def test_cross_currency_ifcash_with_transfer_fee():
# def test_cross_currency_ifcash_no_transfer_fee():
# def test_cross_currency_ifcash_eth():
