import pytest
from brownie import accounts
from scripts.common import TokenType
from tests.constants import SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(scope="module", autouse=True)
def underlying(MockERC20, accounts):
    return MockERC20.deploy("DAI", "DAI", 18, 0, {"from": accounts[0]})


@pytest.fixture(scope="module", autouse=True)
def cToken(MockCToken, accounts, underlying):
    token = MockCToken.deploy(8, {"from": accounts[0]})
    underlying.transfer(token, 100_000_000e18, {"from": accounts[0]})
    token.setAnswer(0.02e28)
    token.setUnderlying(underlying)
    return token


@pytest.fixture(scope="module", autouse=True)
def vaultConfig(MockVaultConfiguration, cToken, cTokenV2Aggregator, accounts, underlying):
    mockVaultConf = MockVaultConfiguration.deploy({"from": accounts[0]})
    aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})
    mockVaultConf.setToken(
        1,
        aggregator.address,
        18,
        (cToken.address, False, TokenType["cToken"], 8, 0),
        (underlying.address, True, TokenType["UnderlyingToken"], 18, 0),
        accounts[9].address,
        {"from": accounts[0]},
    )
    return mockVaultConf


@pytest.fixture(scope="module")
def cTokenVaultConfig(MockVaultConfiguration, MockCToken, cTokenV2Aggregator, MockERC20, accounts):
    mockVaultConf = MockVaultConfiguration.deploy({"from": accounts[0]})

    for currencyId in range(1, 4):
        cToken = MockCToken.deploy(8, {"from": accounts[0]})
        if currencyId == 1:
            underlying = MockERC20.deploy("DAI", "DAI", 18, 0, {"from": accounts[0]})
            underlying.transfer(cToken, 100_000_000e18, {"from": accounts[0]})
            cToken.setAnswer(0.02e28)
        elif currencyId == 2:
            underlying = MockERC20.deploy("TEST", "TEST", 8, 0, {"from": accounts[0]})
            underlying.transfer(cToken, 100_000_000e8, {"from": accounts[0]})
            cToken.setAnswer(0.02e18)
        elif currencyId == 3:
            underlying = MockERC20.deploy("USDC", "USDC", 6, 0, {"from": accounts[0]})
            underlying.transfer(cToken, 100_000_000e6, {"from": accounts[0]})
            cToken.setAnswer(0.02e16)

        cToken.setUnderlying(underlying)
        aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})

        mockVaultConf.setToken(
            currencyId,
            aggregator.address,
            underlying.decimals(),
            (cToken.address, False, TokenType["cToken"], 8, 0),
            (underlying.address, True, TokenType["UnderlyingToken"], underlying.decimals(), 0),
            accounts[10 - currencyId].address,
            {"from": accounts[0]},
        )

    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, vaultConfig, accounts):
    return SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfig.address, 1, {"from": accounts[0]}
    )


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def set_flags(flags, **kwargs):
    binList = list(format(flags, "b").rjust(16, "0"))
    if "ENABLED" in kwargs:
        binList[0] = "1"
    if "ALLOW_ROLL_POSITION" in kwargs:
        binList[1] = "1"
    if "ONLY_VAULT_ENTRY" in kwargs:
        binList[2] = "1"
    if "ONLY_VAULT_EXIT" in kwargs:
        binList[3] = "1"
    if "ONLY_VAULT_ROLL" in kwargs:
        binList[4] = "1"
    if "ONLY_VAULT_DELEVERAGE" in kwargs:
        binList[5] = "1"
    if "TRANSFER_SHARES_ON_DELEVERAGE" in kwargs:
        binList[6] = "1"
    if "ALLOW_REENTRNACY" in kwargs:
        binList[7] = "1"
    return int("".join(reversed(binList)), 2)


def get_vault_config(**kwargs):
    return [
        kwargs.get("flags", 0),  # 0: flags
        kwargs.get("currencyId", 1),  # 1: currency id
        kwargs.get("minAccountBorrowSize", 100_000),  # 2: min account borrow size
        kwargs.get("minCollateralRatioBPS", 2000),  # 3: 20% collateral ratio
        kwargs.get("feeRate5BPS", 20),  # 4: 1% fee
        kwargs.get("liquidationRate", 104),  # 5: 4% liquidation discount
        kwargs.get("reserveFeeShare", 20),  # 6: 20% reserve fee share
        kwargs.get("maxBorrowMarketIndex", 2),  # 7: 20% reserve fee share
    ]


def get_vault_state(**kwargs):
    return [
        kwargs.get("maturity", START_TIME_TREF + SECONDS_IN_QUARTER),
        kwargs.get("totalfCash", 0),
        kwargs.get("isSettled", False),
        kwargs.get("totalVaultShares", 0),
        kwargs.get("totalAssetCash", 0),
        kwargs.get("totalStrategyTokens", 0),
        kwargs.get("totalEscrowedAssetCash", 0),
        kwargs.get("settlementStrategyTokenValue", 0),
    ]


def get_vault_account(**kwargs):
    return [
        kwargs.get("fCash", 0),
        kwargs.get("escrowedAssetCash", 0),
        kwargs.get("maturity", 0),
        kwargs.get("vaultShares", 0),
        kwargs.get("account", accounts[0].address),
        kwargs.get("tempCashBalance", 0),
    ]
