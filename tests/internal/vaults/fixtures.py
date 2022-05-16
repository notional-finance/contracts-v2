import pytest
from brownie import accounts
from scripts.common import TokenType
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(scope="module", autouse=True)
def underlying(MockERC20, accounts):
    return MockERC20.deploy("DAI", "DAI", 18, 0, {"from": accounts[0]})


@pytest.fixture(scope="module", autouse=True)
def cToken(MockCToken, accounts):
    token = MockCToken.deploy(8, {"from": accounts[0]})
    token.setAnswer(0.02e28)
    return token


@pytest.fixture(scope="module", autouse=True)
def vaultConfig(MockVaultConfiguration, cToken, cTokenAggregator, accounts, underlying):
    mockVaultConf = MockVaultConfiguration.deploy({"from": accounts[0]})
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    mockVaultConf.setToken(
        1,
        aggregator.address,
        18,
        (cToken.address, False, TokenType["cToken"], 8, 0),
        (underlying.address, True, TokenType["UnderlyingToken"], 18, 0),
        {"from": accounts[0]},
    )
    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, vaultConfig, accounts):
    return SimpleStrategyVault.deploy(
        "Simple Strategy", "SIMP", vaultConfig.address, 1, {"from": accounts[0]}
    )


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def set_flags(flags, **kwargs):
    binList = list(format(flags, "b").rjust(16, "0"))
    if "ENABLED" in kwargs:
        binList[0] = "1"
    if "ALLOW_REENTER" in kwargs:
        binList[1] = "1"
    if "IS_INSURED" in kwargs:
        binList[2] = "1"
    if "ONLY_VAULT_ENTRY" in kwargs:
        binList[3] = "1"
    if "ONLY_VAULT_EXIT" in kwargs:
        binList[4] = "1"
    if "ONLY_VAULT_ROLL" in kwargs:
        binList[5] = "1"
    if "ONLY_VAULT_DELEVERAGE" in kwargs:
        binList[6] = "1"
    return int("".join(reversed(binList)), 2)


def get_vault_config(**kwargs):
    return [
        kwargs.get("flags", 0),  # 0: flags
        kwargs.get("currencyId", 1),  # 1: currency id
        kwargs.get("maxVaultBorrowSize", 100_000_000e8),  # 2: max vault borrow size
        kwargs.get("minAccountBorrowSize", 100_000),  # 3: min account borrow size
        kwargs.get("minCollateralRatioBPS", 12000),  # 4: 120% collateral ratio
        kwargs.get("termLengthInDays", 90),  # 5: 3 month term
        kwargs.get("maxNTokenFeeRate5BPS", 20),  # 6: 1% fee
        kwargs.get("capacityMultiplierPercentage", 200),  # 7: 200% capacity multiplier
        kwargs.get("liquidationRate", 104),  # 8: 4% liquidation discount
    ]


def get_vault_state(**kwargs):
    return [
        kwargs.get("maturity", START_TIME_TREF + SECONDS_IN_QUARTER),
        kwargs.get("totalfCash", 0),
        kwargs.get("totalfCashRequiringSettlement", 0),
        kwargs.get("isFullySettled", False),
        kwargs.get("accountsRequiringSettlement", 0),
        kwargs.get("totalVaultShares", 0),
        kwargs.get("totalAssetCash", 0),
        kwargs.get("totalStrategyTokens", 0),
    ]


def get_vault_account(**kwargs):
    return [
        kwargs.get("fCash", 0),
        kwargs.get("escrowedAssetCash", 0),
        kwargs.get("maturity", 0),
        kwargs.get("vaultShares", 0),
        kwargs.get("requiresSettlement", False),
        kwargs.get("account", accounts[0].address),
        kwargs.get("tempCashBalance", 0),
    ]
