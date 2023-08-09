import pytest
from brownie import accounts
from brownie.convert.datatypes import HexString
from brownie.network.contract import Contract
from scripts.common import TokenType
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF, ZERO_ADDRESS
from tests.helpers import setup_internal_mock


@pytest.fixture(scope="module", autouse=True)
def vaultConfigState(MockVaultConfigurationState, MockSettingsLib, accounts):
    settings = MockSettingsLib.deploy({"from": accounts[0]})
    mockVaultConf = MockVaultConfigurationState.deploy(settings, {"from": accounts[0]})
    mockVaultConf = Contract.from_abi(
        "mock", mockVaultConf.address, MockSettingsLib.abi + mockVaultConf.abi, owner=accounts[0]
    )
    tokens = setup_internal_mock(mockVaultConf)
    mockVaultConf.setToken(1, (ZERO_ADDRESS, False, TokenType["Ether"], 18, 0))
    mockVaultConf.setToken(2, (tokens["DAI"], False, TokenType["UnderlyingToken"], 18, 0))
    mockVaultConf.setToken(3, (tokens["USDC"], False, TokenType["UnderlyingToken"], 6, 0))
    mockVaultConf.setToken(4, (tokens["WBTC"], False, TokenType["UnderlyingToken"], 8, 0))

    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vaultConfigTokenTransfer(MockVaultTokenTransfers, accounts, MockSettingsLib):
    settings = MockSettingsLib.deploy({"from": accounts[0]})
    mockVaultConf = MockVaultTokenTransfers.deploy(settings, {"from": accounts[0]})
    mockVaultConf = Contract.from_abi(
        "mock", mockVaultConf.address, MockSettingsLib.abi + mockVaultConf.abi, owner=accounts[0]
    )
    tokens = setup_internal_mock(mockVaultConf)
    mockVaultConf.setToken(1, (ZERO_ADDRESS, False, TokenType["Ether"], 18, 0))
    mockVaultConf.setToken(2, (tokens["DAI"], False, TokenType["UnderlyingToken"], 18, 0))
    mockVaultConf.setToken(3, (tokens["USDC"], False, TokenType["UnderlyingToken"], 6, 0))
    mockVaultConf.setToken(4, (tokens["WBTC"], False, TokenType["UnderlyingToken"], 8, 0))

    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vaultConfigAccount(MockVaultAccount, accounts, MockSettingsLib):
    settings = MockSettingsLib.deploy({"from": accounts[0]})
    mockVaultConf = MockVaultAccount.deploy(settings, {"from": accounts[0]})
    mockVaultConf = Contract.from_abi(
        "mock", mockVaultConf.address, MockSettingsLib.abi + mockVaultConf.abi, owner=accounts[0]
    )
    tokens = setup_internal_mock(mockVaultConf)
    mockVaultConf.setToken(1, (ZERO_ADDRESS, False, TokenType["Ether"], 18, 0))
    mockVaultConf.setToken(2, (tokens["DAI"], False, TokenType["UnderlyingToken"], 18, 0))
    mockVaultConf.setToken(3, (tokens["USDC"], False, TokenType["UnderlyingToken"], 6, 0))
    mockVaultConf.setToken(4, (tokens["WBTC"], False, TokenType["UnderlyingToken"], 8, 0))

    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vaultConfigSecondaryBorrow(MockVaultSecondaryBorrow, accounts, MockSettingsLib):
    settings = MockSettingsLib.deploy({"from": accounts[0]})
    mockVaultConf = MockVaultSecondaryBorrow.deploy(settings, {"from": accounts[0]})
    mockVaultConf = Contract.from_abi(
        "mock", mockVaultConf.address, MockSettingsLib.abi + mockVaultConf.abi, owner=accounts[0]
    )
    tokens = setup_internal_mock(mockVaultConf)
    mockVaultConf.setToken(1, (ZERO_ADDRESS, False, TokenType["Ether"], 18, 0))
    mockVaultConf.setToken(2, (tokens["DAI"], False, TokenType["UnderlyingToken"], 18, 0))
    mockVaultConf.setToken(3, (tokens["USDC"], False, TokenType["UnderlyingToken"], 6, 0))
    mockVaultConf.setToken(4, (tokens["WBTC"], False, TokenType["UnderlyingToken"], 8, 0))

    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vaultConfigValuation(MockVaultValuation, accounts, MockSettingsLib):
    settings = MockSettingsLib.deploy({"from": accounts[0]})
    mockVaultConf = MockVaultValuation.deploy(settings, {"from": accounts[0]})
    mockVaultConf = Contract.from_abi(
        "mock", mockVaultConf.address, MockSettingsLib.abi + mockVaultConf.abi, owner=accounts[0]
    )
    tokens = setup_internal_mock(mockVaultConf)
    mockVaultConf.setToken(1, (ZERO_ADDRESS, False, TokenType["Ether"], 18, 0))
    mockVaultConf.setToken(2, (tokens["DAI"], False, TokenType["UnderlyingToken"], 18, 0))
    mockVaultConf.setToken(3, (tokens["USDC"], False, TokenType["UnderlyingToken"], 6, 0))
    mockVaultConf.setToken(4, (tokens["WBTC"], False, TokenType["UnderlyingToken"], 8, 0))

    return mockVaultConf


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def set_flags(flags, **kwargs):
    binList = list(format(flags, "b").rjust(16, "0"))
    if "ENABLED" in kwargs and kwargs["ENABLED"]:
        binList[0] = "1"
    if "ALLOW_ROLL_POSITION" in kwargs and kwargs["ALLOW_ROLL_POSITION"]:
        binList[1] = "1"
    if "ONLY_VAULT_ENTRY" in kwargs and kwargs["ONLY_VAULT_ENTRY"]:
        binList[2] = "1"
    if "ONLY_VAULT_EXIT" in kwargs and kwargs["ONLY_VAULT_EXIT"]:
        binList[3] = "1"
    if "ONLY_VAULT_ROLL" in kwargs and kwargs["ONLY_VAULT_ROLL"]:
        binList[4] = "1"
    if "ONLY_VAULT_DELEVERAGE" in kwargs and kwargs["ONLY_VAULT_DELEVERAGE"]:
        binList[5] = "1"
    if "ONLY_VAULT_SETTLE" in kwargs and kwargs["ONLY_VAULT_SETTLE"]:
        binList[6] = "1"
    if "ALLOW_REENTRANCY" in kwargs and kwargs["ALLOW_REENTRANCY"]:
        binList[7] = "1"
    if "DISABLE_DELEVERAGE" in kwargs and kwargs["DISABLE_DELEVERAGE"]:
        binList[8] = "1"
    if "ENABLE_FCASH_DISCOUNT" in kwargs and kwargs["ENABLE_FCASH_DISCOUNT"]:
        binList[9] = "1"
    return int("".join(reversed(binList)), 2)


def get_vault_config(**kwargs):
    return [
        kwargs.get("flags", 0),  # 0: flags
        kwargs.get("currencyId", 1),  # 1: currency id
        kwargs.get("minAccountBorrowSize", 100_000e8),  # 2: min account borrow size
        kwargs.get("minCollateralRatioBPS", 2000),  # 3: 20% collateral ratio
        kwargs.get("feeRate5BPS", 20),  # 4: 1% fee
        kwargs.get("liquidationRate", 104),  # 5: 4% liquidation discount
        kwargs.get("reserveFeeShare", 20),  # 6: 20% reserve fee share
        kwargs.get("maxBorrowMarketIndex", 2),  # 7: 20% reserve fee share
        kwargs.get("maxDeleverageCollateralRatioBPS", 4000),  # 8: 40% max collateral ratio
        kwargs.get("secondaryBorrowCurrencies", [0, 0]),  # 9: none set
        kwargs.get("maxRequiredAccountCollateralRatio", 20000),  # 10: none set
        kwargs.get("minAccountSecondaryBorrow", [0, 0]),  # 10: none set
        kwargs.get("excessCashLiquidationBonus", 100),  # 10: none set
    ]


def get_vault_state(**kwargs):
    return [
        kwargs.get("maturity", START_TIME_TREF + SECONDS_IN_QUARTER),
        kwargs.get("totalDebtUnderlying", 0),
        kwargs.get("totalVaultShares", 0),
        kwargs.get("isSettled", False),
    ]


def get_vault_account(**kwargs):
    return [
        kwargs.get("accountDebtUnderlying", 0),
        kwargs.get("maturity", 0),
        kwargs.get("vaultShares", 0),
        kwargs.get("account", accounts[0].address),
        kwargs.get("tempCashBalance", 0),
        kwargs.get("lastUpdateBlockTime", 0),
    ]
