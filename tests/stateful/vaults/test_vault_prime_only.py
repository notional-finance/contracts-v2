import brownie
import pytest
from fixtures import *
from tests.constants import PRIME_CASH_VAULT_MATURITY 
from tests.internal.vaults.fixtures import get_vault_config, set_flags
from tests.stateful.invariants import check_system_invariants

@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

def test_can_only_enter_in_prime(environment, vault, accounts):
    environment.notional.updateVault(
        vault.address,
        get_vault_config(
            currencyId=2,
            flags=set_flags(0, ENABLED=True),
            maxBorrowMarketIndex=0,
            maxDeleverageCollateralRatioBPS=2500,
            maxRequiredAccountCollateralRatio=3000,
        ),
        500_000e8,
    )

    with brownie.reverts(dev_revert_msg="dev: invalid maturity"):
        maturity = environment.notional.getActiveMarkets(2)[0][1]
        environment.notional.enterVault(
            accounts[1], vault.address, 25_000e18, maturity, 100_000e8, 0, "", {"from": accounts[1]}
        )

    environment.notional.enterVault(
        accounts[1], vault.address, 25_000e18, PRIME_CASH_VAULT_MATURITY, 100_000e8, 0, "", {"from": accounts[1]}
    )

    check_system_invariants(environment, accounts, [vault])


