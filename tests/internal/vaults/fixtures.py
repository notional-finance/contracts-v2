import pytest
from brownie import accounts
from brownie.convert.datatypes import HexString
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
def vaultConfigState(MockVaultConfigurationState, cToken, cTokenV2Aggregator, accounts, underlying):
    mockVaultConf = MockVaultConfigurationState.deploy({"from": accounts[0]})
    aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})
    mockVaultConf.setToken(
        1,
        aggregator.address,
        18,
        (cToken.address, False, TokenType["cToken"], 8, 0),
        (underlying.address, False, TokenType["UnderlyingToken"], 18, 0),
        accounts[9].address,
        {"from": accounts[0]},
    )
    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vaultConfigAccount(
    MockVaultConfigurationAccount, cToken, cTokenV2Aggregator, accounts, underlying
):
    mockVaultConf = MockVaultConfigurationAccount.deploy({"from": accounts[0]})
    aggregator = cTokenV2Aggregator.deploy(cToken.address, {"from": accounts[0]})
    mockVaultConf.setToken(
        1,
        aggregator.address,
        18,
        (cToken.address, False, TokenType["cToken"], 8, 0),
        (underlying.address, False, TokenType["UnderlyingToken"], 18, 0),
        accounts[9].address,
        {"from": accounts[0]},
    )
    return mockVaultConf


@pytest.fixture(scope="module")
def cTokenVaultConfig(
    MockVaultConfigurationAccount, MockCToken, cTokenV2Aggregator, MockERC20, accounts
):
    mockVaultConf = MockVaultConfigurationAccount.deploy({"from": accounts[0]})

    cETH = MockCToken.deploy(8, {"from": accounts[0]})
    aggregator = cTokenV2Aggregator.deploy(cETH.address, {"from": accounts[0]})
    mockVaultConf.setToken(
        1,
        aggregator.address,
        18,
        (cETH.address, False, TokenType["cETH"], 8, 0),
        (HexString(0, "bytes20"), False, TokenType["Ether"], 18, 0),
        accounts[9].address,
        {"from": accounts[0]},
    )
    cETH.setAnswer(0.02e28)

    for currencyId in range(2, 5):
        cToken = MockCToken.deploy(8, {"from": accounts[0]})
        if currencyId == 2:
            underlying = MockERC20.deploy("DAI", "DAI", 18, 0, {"from": accounts[0]})
            underlying.transfer(cToken, 100_000_000e18, {"from": accounts[0]})
            cToken.setAnswer(0.02e28)
        elif currencyId == 3:
            # Has transfer fee
            underlying = MockERC20.deploy("TEST", "TEST", 8, 0.01e18, {"from": accounts[0]})
            underlying.transfer(cToken, 100_000_000e8, {"from": accounts[0]})
            cToken.setAnswer(0.02e18)
        elif currencyId == 4:
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
            (
                underlying.address,
                currencyId == 3,
                TokenType["UnderlyingToken"],
                underlying.decimals(),
                0,
            ),
            accounts[10 - currencyId].address,
            {"from": accounts[0]},
        )

    # NOMINT
    underlying = MockERC20.deploy("NOMINT", "NOMINT", 18, 0, {"from": accounts[0]})
    mockVaultConf.setToken(
        5,
        HexString(0, "bytes20"),
        underlying.decimals(),
        (underlying.address, False, TokenType["NonMintable"], 18, 0),
        (HexString(0, "bytes20"), False, TokenType["UnderlyingToken"], 0, 0),
        accounts[10 - 5].address,
        {"from": accounts[0]},
    )

    return mockVaultConf


@pytest.fixture(scope="module", autouse=True)
def vault(SimpleStrategyVault, vaultConfigAccount, accounts):
    return SimpleStrategyVault.deploy(
        "Simple Strategy", vaultConfigAccount.address, 1, {"from": accounts[0]}
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
    if "ONLY_VAULT_SETTLE" in kwargs:
        binList[6] = "1"
    if "ALLOW_REENTRANCY" in kwargs:
        binList[7] = "1"
    if "DISABLE_DELEVERAGE" in kwargs:
        binList[8] = "1"
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
        kwargs.get("maxDeleverageCollateralRatioBPS", 4000),  # 8: 40% max collateral ratio
        kwargs.get("secondaryBorrowCurrencies", [0, 0]),  # 9: none set
        kwargs.get("maxRequiredAccountCollateralRatio", 20000),  # 10: none set
    ]


def get_vault_state(**kwargs):
    return [
        kwargs.get("maturity", START_TIME_TREF + SECONDS_IN_QUARTER),
        kwargs.get("totalfCash", 0),
        kwargs.get("isSettled", False),
        kwargs.get("totalVaultShares", 0),
        kwargs.get("totalAssetCash", 0),
        kwargs.get("totalStrategyTokens", 0),
        kwargs.get("settlementStrategyTokenValue", 0),
    ]


def get_vault_account(**kwargs):
    return [
        kwargs.get("fCash", 0),
        kwargs.get("maturity", 0),
        kwargs.get("vaultShares", 0),
        kwargs.get("account", accounts[0].address),
        kwargs.get("tempCashBalance", 0),
        kwargs.get("lastEntryBlockHeight", 0),
    ]
