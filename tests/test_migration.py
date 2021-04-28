import pytest
import scripts.deploy_v1
from brownie.convert.datatypes import Wei
from brownie.network.contract import Contract
from brownie.network.state import Chain
from brownie.project import ContractsVProject
from tests.helpers import initialize_environment

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    v2env = initialize_environment(accounts)
    v1env = scripts.deploy_v1.deploy_v1(v2env)

    blockTime = chain.time()
    cashMarketABI = ContractsVProject._build.get("CashMarketInterface")["abi"]
    cashMarket = Contract.from_abi(
        "CashMarket",
        v1env["Portfolios"].functions.cashGroups(1).call()[3],
        abi=cashMarketABI,
        owner=accounts[0],
    )
    daiMaturities = cashMarket.getActiveMaturities()

    # borrow dai w/ eth
    erc1155 = Contract.from_abi(
        "ERC1155Trade", address=v1env["ERC1155Trade"].address, abi=v1env["ERC1155Trade"].abi
    )

    erc1155.batchOperationWithdraw(
        accounts[1].address,
        blockTime + 100000,
        [],  # deposit 10 eth
        [(0, 1, daiMaturities[0], Wei(100e18), bytes())],  # borrow 100 dai
        [(accounts[1].address, 1, 0)],  # withdraw all
        {"from": accounts[1], "value": Wei(10e18)},
    )

    # borrow dai w/ wbtc
    v2env.token["WBTC"].transfer(accounts[2], 100e8, {"from": accounts[0]})
    v2env.token["WBTC"].approve(v1env["Escrow"].address, 2 ** 255, {"from": accounts[2]})
    erc1155.batchOperationWithdraw(
        accounts[2].address,
        blockTime + 100000,
        [(3, 10e8)],  # deposit 10 btc
        [(0, 1, daiMaturities[0], Wei(100e18), bytes())],  # borrow 100 dai
        [(accounts[2].address, 1, 0)],  # withdraw all
        {"from": accounts[2]},
    )
    # borrow usdc w/ eth
    erc1155.batchOperationWithdraw(
        accounts[3].address,
        blockTime + 100000,
        [],  # deposit eth
        [(0, 2, daiMaturities[0], 100e6, bytes())],  # borrow 100 usdc
        [(accounts[3].address, 2, 0)],  # withdraw all
        {"from": accounts[3], "value": 10e18},
    )
    # borrow usdc w/ wbtc
    v2env.token["WBTC"].transfer(accounts[4], 100e8, {"from": accounts[0]})
    v2env.token["WBTC"].approve(v1env["Escrow"].address, 2 ** 255, {"from": accounts[4]})
    erc1155.batchOperationWithdraw(
        accounts[4].address,
        blockTime + 100000,
        [(3, 10e8)],  # deposit btc
        [(0, 2, daiMaturities[0], 100e6, bytes())],  # borrow 100 usdc
        [(accounts[4].address, 2, 0)],  # withdraw all
        {"from": accounts[4], "value": 10e18},
    )

    v2env.notional.updateGlobalTransferOperator(v1env["Migrator"].address, True)

    return (v1env, v2env)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.mark.only
def test_migrate_dai_eth(environment, accounts):
    account = accounts[1]
    (v1env, v2env) = environment
    erc1155 = Contract.from_abi(
        "ERC1155Trade", address=v1env["ERC1155Trade"].address, abi=v1env["ERC1155Trade"].abi
    )
    erc1155.setApprovalForAll(v1env["Migrator"].address, True, {"from": account})
    v2env.token["DAI"].approve(v1env["Escrow"].address, 2 ** 255, {"from": account})
    v1env["Migrator"].migrateDaiEther(1, 100e8, 0, 100e18, {"from": account})

    assert False


def test_migrate_dai_wbtc(environment, accounts):
    account = accounts[2]
    (v1env, v2env) = environment
    erc1155 = Contract.from_abi(
        "ERC1155Trade", address=v1env["ERC1155Trade"].address, abi=v1env["ERC1155Trade"].abi
    )
    erc1155.setApprovalForAll(v1env["Migrator"].address, True, {"from": account})
    v2env.token["DAI"].approve(v1env["Escrow"].address, 2 ** 255, {"from": account})
    v1env["Migrator"].migrateDaiWBTC(1, 100e8, 0, 100e18, {"from": account})


# def test_migrate_usdc_eth(environment, accounts):
#     account = accounts[3]
#     pass


# def test_migrate_usdc_wbtc(environment, accounts):
#     account = accounts[4]
#     pass
