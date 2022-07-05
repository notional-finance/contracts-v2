import brownie
import pytest
from brownie import MockERC20, cTokenV2Aggregator
from brownie.convert.datatypes import HexString
from scripts.mainnet.EnvironmentConfig import getEnvironment
from tests.helpers import get_balance_trade_action


@pytest.fixture(autouse=True)
def env():
    e = getEnvironment()
    return e


def test_list_wsteth(env, accounts):
    env.notional.listCurrency(
        [
            "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
            False,  # No transfer fee
            4,  # NOMINT
            18,  # Decimals
            22500e8,  # Max balance (approx: 24,162 stETH, 43.5 million USD @ $1800)
        ],
        [HexString(0, type_str="bytes20"), False, 0, 0, 0],
        "0x54BD2A9e54532FF28CDB9208578f63788549B127",
        False,  # Must Invert = False
        110,  # Buffer
        72,  # Haircut
        108,  # Liquidation
        {"from": env.notional.owner()},
    )
    wstETH = MockERC20.at("0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0")

    wstETHWhale = accounts.at("0x10cd5fbe1b404b7e19ef964b63939907bdaf42e2", force=True)
    wstETH.approve(env.notional.address, 2 ** 255, {"from": wstETHWhale})

    with brownie.reverts():
        env.notional.depositUnderlyingToken(wstETHWhale, 5, 200e18, {"from": wstETHWhale})

    env.notional.depositAssetToken(wstETHWhale, 5, 200e18, {"from": wstETHWhale})

    # Reverts over max balance
    with brownie.reverts():
        env.notional.depositAssetToken(wstETHWhale, 5, 23_000e18, {"from": wstETHWhale})

    balanceBefore = wstETH.balanceOf(wstETHWhale)
    env.notional.withdraw(5, 200e8, False, {"from": wstETHWhale})
    balanceAfter = wstETH.balanceOf(wstETHWhale)

    assert balanceAfter - balanceBefore == 200e18

    # Borrow with stETH as collateral
    assert env.notional.getAccountBalance(5, wstETHWhale) == (0, 0, 0)
    collateral = get_balance_trade_action(5, "DepositAsset", [], depositActionAmount=2e18)

    borrowAction = get_balance_trade_action(
        3,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 3000e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
    )

    with brownie.reverts("Insufficient free collateral"):
        env.notional.batchBalanceAndTradeAction(
            wstETHWhale, [borrowAction, collateral], {"from": wstETHWhale}
        )

    borrowAction = get_balance_trade_action(
        3,
        "None",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 2500e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
    )
    env.notional.batchBalanceAndTradeAction(
        wstETHWhale, [borrowAction, collateral], {"from": wstETHWhale}
    )


@pytest.mark.only
def test_aggregators(env, accounts):
    dai = cTokenV2Aggregator.at("0x719993E82974f5b5eA0c5ebA25c260CD5AF78E00")
    eth = cTokenV2Aggregator.at("0x8E3D447eBE244db6D28E2303bCa86Ef3033CFAd6")
    usdc = cTokenV2Aggregator.at("0x612741825ACedC6F88D8709319fe65bCB015C693")
    wbtc = cTokenV2Aggregator.at("0x39D9590721331B13C8e9A42941a2B961B513E69d")

    assert eth.getExchangeRateView() == eth.getExchangeRateStateful.call()
    assert dai.getExchangeRateView() == dai.getExchangeRateStateful.call()
    assert usdc.getExchangeRateView() == usdc.getExchangeRateStateful.call()
    assert wbtc.getExchangeRateView() == wbtc.getExchangeRateStateful.call()
