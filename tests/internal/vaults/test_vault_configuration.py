import brownie
import pytest
from brownie.convert.datatypes import Wei
from brownie.test import given, strategy
from scripts.common import TokenType
from tests.constants import BASIS_POINT, RATE_PRECISION, SECONDS_IN_QUARTER, START_TIME_TREF


@pytest.fixture(scope="module", autouse=True)
def vaultConfig(MockVaultConfiguration, MockERC20, MockCToken, cTokenAggregator, accounts):
    underlying = MockERC20.deploy("DAI", "DAI", 18, 0, {"from": accounts[0]})
    cToken = MockCToken.deploy(8, {"from": accounts[0]})
    cToken.setAnswer(50e28)
    aggregator = cTokenAggregator.deploy(cToken.address, {"from": accounts[0]})
    mockVaultConf = MockVaultConfiguration.deploy({"from": accounts[0]})
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


def get_vault_config(**kwargs):
    return [
        kwargs.get("flags", 0),  # 0: flags
        kwargs.get("currencyId", 1),  # 1: currency id
        kwargs.get("maxVaultBorrowSize", 100_000_000e8),  # 2: max vault borrow size
        kwargs.get("minAccountBorrowSize", 100_000),  # 3: min account borrow size
        kwargs.get("maxLeverageRatioBPS", 20000),  # 4: 200% leverage ratio
        kwargs.get("termLengthInDays", 90),  # 5: 3 month term
        kwargs.get("maxNTokenFeeRate5BPS", 20),  # 6: 1% fee
        kwargs.get("capacityMultiplierPercentage", 200),  # 7: 200% capacity multiplier
        kwargs.get("liquidationRate", 104),  # 8: 4% liquidation discount
    ]


def test_set_vault_config(vaultConfig, accounts):
    conf = get_vault_config()
    with brownie.reverts():
        # Fails on leverage ratio less than 1
        conf[4] = 100
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    with brownie.reverts():
        # Fails on liquidation ratio less than 100
        conf[8] = 99
        vaultConfig.setVaultConfig(accounts[0], conf)

    conf = get_vault_config()
    vaultConfig.setVaultConfig(accounts[0], conf)

    config = vaultConfig.getVaultConfigView(accounts[0]).dict()
    assert config["vault"] == accounts[0].address
    assert config["flags"] == conf[0]
    assert config["borrowCurrencyId"] == conf[1]
    assert config["maxVaultBorrowSize"] == conf[2]
    assert config["minAccountBorrowSize"] == conf[3] * 1e8
    assert config["maxLeverageRatio"] == conf[4] * BASIS_POINT
    assert config["termLengthInSeconds"] == conf[5] * 86400
    assert config["maxNTokenFeeRate"] == conf[6] * 5 * BASIS_POINT
    assert config["capacityMultiplierPercentage"] == conf[7]
    assert config["liquidationRate"] == conf[8]


def test_pause_and_enable_vault(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    # Asserts are inside the method
    vaultConfig.setVaultEnabledStatus(accounts[0], True)
    vaultConfig.setVaultEnabledStatus(accounts[0], False)


def test_current_maturity(vaultConfig, accounts):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config())

    currentMaturity = vaultConfig.getCurrentMaturity(accounts[0], START_TIME_TREF)
    assert currentMaturity == START_TIME_TREF + SECONDS_IN_QUARTER


@given(leverageRatio=strategy("uint", min_value=0, max_value=RATE_PRECISION))
def test_ntoken_fee_no_leverage(vaultConfig, accounts, leverageRatio):
    vaultConfig.setVaultConfig(accounts[0], get_vault_config(maxNTokenFeeRate5BPS=255))

    # no fee when under min leverage
    assert vaultConfig.getNTokenFee(accounts[0], leverageRatio, 100_000e8, SECONDS_IN_QUARTER) == 0


def test_ntoken_fee_increases_with_leverage(vaultConfig, accounts):
    vaultConfig.setVaultConfig(
        accounts[0],
        get_vault_config(maxNTokenFeeRate5BPS=255, maxLeverageRatioBPS=40000),  # max 400% leverage
    )

    leverageRatio = RATE_PRECISION
    maxLeverageRatio = 4 * RATE_PRECISION
    # go over the max leverage ratio and see what happens to the fee
    increment = Wei((maxLeverageRatio - leverageRatio) / 18)
    lastFee = 0
    for i in range(0, 20):
        leverageRatio += increment
        fee = vaultConfig.getNTokenFee(accounts[0], leverageRatio, -100_000e8, SECONDS_IN_QUARTER)
        assert fee > lastFee
        lastFee = fee


def test_ntoken_fee_increases_with_debt(vaultConfig, accounts):
    vaultConfig.setVaultConfig(
        accounts[0],
        get_vault_config(maxNTokenFeeRate5BPS=255, maxLeverageRatioBPS=40000),  # max 400% leverage
    )

    assert vaultConfig.getNTokenFee(accounts[0], 2 * RATE_PRECISION, 0, SECONDS_IN_QUARTER) == 0

    fCash = 0
    decrement = 100e8
    lastFee = 0
    for i in range(0, 20):
        fCash -= decrement
        fee = vaultConfig.getNTokenFee(accounts[0], 2 * RATE_PRECISION, fCash, SECONDS_IN_QUARTER)
        assert fee > lastFee
        lastFee = fee


def test_ntoken_fee_increases_with_time_to_maturity(vaultConfig, accounts):
    vaultConfig.setVaultConfig(
        accounts[0],
        get_vault_config(maxNTokenFeeRate5BPS=255, maxLeverageRatioBPS=40000),  # max 400% leverage
    )

    assert vaultConfig.getNTokenFee(accounts[0], 2 * RATE_PRECISION, 100_000e8, 0) == 0

    timeToMaturity = 0
    # go over the max leverage ratio and see what happens to the fee
    increment = Wei(SECONDS_IN_QUARTER / 20)
    lastFee = 0
    for i in range(0, 20):
        timeToMaturity += increment
        fee = vaultConfig.getNTokenFee(accounts[0], 2 * RATE_PRECISION, -100_000e8, timeToMaturity)
        assert fee > lastFee
        lastFee = fee


# def test_max_borrow_capacity_old_maturity(vaultConfig, accounts):
#     pass

# def test_max_borrow_capacity_current_maturity(vaultConfig, accounts):
#     pass

# def test_max_borrow_capacity_next_maturity(vaultConfig, accounts):
#     pass

# def test_max_borrow_capacity_old_maturity_in_settlement(vaultConfig, accounts):
#     pass

# def test_max_borrow_capacity_current_maturity_in_settlement(vaultConfig, accounts):
#     pass

# def test_max_borrow_capacity_next_maturity_in_settlement(vaultConfig, accounts):
#     pass


# def test_deposit_ctoken(vaultConfig, vault, accounts):
#     pass

# def test_deposit_atoken(vaultConfig, vault, accounts):
#     pass

# def test_redeem_ctoken(vaultConfig, vault, accounts):
#     pass

# def test_redeem_atoken(vaultConfig, vault, accounts):
#     pass
