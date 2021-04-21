import brownie
import pytest
from brownie.convert import to_bytes
from brownie.network import web3
from brownie.network.state import Chain
from tests.constants import RATE_PRECISION, SECONDS_IN_DAY
from tests.helpers import get_balance_action, get_balance_trade_action, initialize_environment
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    env = initialize_environment(accounts)
    env.notional.enableBitmapCurrency(2, {"from": accounts[2]})

    return env


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_transfer_authentication_failures(environment, accounts):
    addressZero = to_bytes(0, "bytes20")
    markets = environment.notional.getActiveMarkets(2)
    erc1155id = environment.notional.encodeToId(2, markets[0][1], 1)

    with brownie.reverts("Invalid address"):
        environment.notional.safeTransferFrom(accounts[0], addressZero, erc1155id, 100e8, "")
        environment.notional.safeBatchTransferFrom(
            accounts[0], addressZero, [erc1155id], [100e8], ""
        )

    with brownie.reverts("Invalid address"):
        environment.notional.safeTransferFrom(accounts[0], accounts[0], erc1155id, 100e8, "")
        environment.notional.safeBatchTransferFrom(
            accounts[0], accounts[0], [erc1155id], [100e8], ""
        )

    with brownie.reverts("Unauthorized"):
        environment.notional.safeTransferFrom(addressZero, accounts[1], erc1155id, 100e8, "")
        environment.notional.safeBatchTransferFrom(
            addressZero, accounts[1], [erc1155id], [100e8], ""
        )

    with brownie.reverts("Unauthorized"):
        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, "", {"from": accounts[0]}
        )
        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], "", {"from": accounts[0]}
        )

    with brownie.reverts("Invalid maturity"):
        # Does not fall on a valid utc0 date
        erc1155id = environment.notional.encodeToId(2, markets[0][1] + 10, 1)

        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, "", {"from": accounts[0]}
        )
        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], "", {"from": accounts[0]}
        )


def test_transfer_invalid_maturity(environment, accounts):
    markets = environment.notional.getActiveMarkets(2)

    with brownie.reverts("Invalid maturity"):
        # Does not fall on a valid utc0 date
        erc1155id = environment.notional.encodeToId(2, markets[0][1] + 10, 1)

        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, "", {"from": accounts[1]}
        )
        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], "", {"from": accounts[1]}
        )

    with brownie.reverts("Invalid maturity"):
        # Is past max market date
        erc1155id = environment.notional.encodeToId(2, markets[-1][1] + SECONDS_IN_DAY, 1)

        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, "", {"from": accounts[1]}
        )
        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], "", {"from": accounts[1]}
        )

    with brownie.reverts("Invalid maturity"):
        # Is in the past
        blockTime = chain.time()
        blockTime = blockTime - blockTime % SECONDS_IN_DAY - SECONDS_IN_DAY
        erc1155id = environment.notional.encodeToId(2, blockTime, 1)

        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, "", {"from": accounts[1]}
        )
        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], "", {"from": accounts[1]}
        )


def test_calldata_encoding_failure(environment, accounts):
    markets = environment.notional.getActiveMarkets(2)
    erc1155id = environment.notional.encodeToId(2, markets[0][1], 1)

    with brownie.reverts("Insufficient free collateral"):
        # This should fall through the sig check and fail
        data = web3.eth.contract(abi=environment.notional.abi).encodeABI(
            fn_name="transferOwnership", args=[accounts[0].address]
        )

        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, data, {"from": accounts[1]}
        )

        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], data, {"from": accounts[1]}
        )

    with brownie.reverts("Unauthorized call"):
        data = web3.eth.contract(abi=environment.notional.abi).encodeABI(
            fn_name="batchBalanceAction",
            args=[
                accounts[0].address,
                [get_balance_action(2, "DepositAsset", depositActionAmount=100e8)],
            ],
        )

        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, data, {"from": accounts[1]}
        )

        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], data, {"from": accounts[1]}
        )


def test_fail_on_non_acceptance(environment, accounts, MockTransferOperator):
    markets = environment.notional.getActiveMarkets(2)
    erc1155id = environment.notional.encodeToId(2, markets[0][1], 1)
    transferOp = MockTransferOperator.deploy(environment.notional.address, {"from": accounts[0]})
    transferOp.setShouldReject(True)

    with brownie.reverts("Not accepted"):
        environment.notional.safeTransferFrom(
            accounts[1], transferOp.address, erc1155id, 100e8, bytes(), {"from": accounts[1]}
        )

        environment.notional.safeBatchTransferFrom(
            accounts[1], transferOp.address, [erc1155id], [100e8], bytes(), {"from": accounts[1]}
        )

    with brownie.reverts("Not accepted"):
        # nTokens will reject ERC1155 transfers
        environment.notional.safeTransferFrom(
            accounts[0], environment.nToken[1], erc1155id, 100e8, ""
        )
        environment.notional.safeBatchTransferFrom(
            accounts[0], environment.nToken[1], [erc1155id], [100e8], ""
        )


def test_set_account_approval(environment, accounts):
    assert not environment.notional.isApprovedForAll(accounts[0], accounts[1])
    environment.notional.setApprovalForAll(accounts[1], True, {"from": accounts[0]})
    assert environment.notional.isApprovedForAll(accounts[0], accounts[1])
    environment.notional.setApprovalForAll(accounts[1], False, {"from": accounts[0]})
    assert not environment.notional.isApprovedForAll(accounts[0], accounts[1])


def test_set_global_approval(environment, accounts, MockTransferOperator):
    transferOp = MockTransferOperator.deploy(environment.notional.address, {"from": accounts[0]})
    assert not environment.notional.isApprovedForAll(accounts[0], transferOp.address)

    txn = environment.notional.updateGlobalTransferOperator(
        transferOp.address, True, {"from": accounts[0]}
    )

    assert txn.events["UpdateGlobalTransferOperator"]["operator"] == transferOp.address
    assert txn.events["UpdateGlobalTransferOperator"]["approved"]
    assert environment.notional.isApprovedForAll(accounts[0], transferOp.address)

    txn = environment.notional.updateGlobalTransferOperator(
        transferOp.address, False, {"from": accounts[0]}
    )
    assert txn.events["UpdateGlobalTransferOperator"]["operator"] == transferOp.address
    assert not txn.events["UpdateGlobalTransferOperator"]["approved"]
    assert not environment.notional.isApprovedForAll(accounts[0], transferOp.address)


def test_transfer_has_fcash(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5100e8,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    assets = environment.notional.getAccountPortfolio(accounts[1])
    erc1155id = environment.notional.encodeToId(assets[0][0], assets[0][1], assets[0][2])

    txn = environment.notional.safeTransferFrom(
        accounts[1], accounts[0], erc1155id, 10e8, bytes(), {"from": accounts[1]}
    )

    assert txn.events["TransferSingle"]["from"] == accounts[1]
    assert txn.events["TransferSingle"]["to"] == accounts[0]
    assert txn.events["TransferSingle"]["id"] == erc1155id
    assert txn.events["TransferSingle"]["value"] == 10e8

    toAssets = environment.notional.getAccountPortfolio(accounts[0])
    assert toAssets[0][0] == assets[0][0]
    assert toAssets[0][1] == assets[0][1]
    assert toAssets[0][2] == assets[0][2]
    assert toAssets[0][3] == 10e8

    # Tests transfer to bitmap account
    environment.notional.safeTransferFrom(
        accounts[1], accounts[2], erc1155id, 10e8, bytes(), {"from": accounts[1]}
    )
    toAssets = environment.notional.getAccountPortfolio(accounts[2])
    assert toAssets[0][0] == assets[0][0]
    assert toAssets[0][1] == assets[0][1]
    assert toAssets[0][2] == assets[0][2]
    assert toAssets[0][3] == 10e8

    check_system_invariants(environment, accounts)


def test_batch_transfer_has_fcash(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0},
            {"tradeActionType": "Lend", "marketIndex": 2, "notional": 100e8, "minSlippage": 0},
        ],
        depositActionAmount=12000e8,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    assets = environment.notional.getAccountPortfolio(accounts[1])
    erc1155ids = [
        environment.notional.encodeToId(assets[0][0], assets[0][1], assets[0][2]),
        environment.notional.encodeToId(assets[1][0], assets[1][1], assets[1][2]),
    ]
    txn = environment.notional.safeBatchTransferFrom(
        accounts[1], accounts[0], erc1155ids, [10e8, 10e8], bytes(), {"from": accounts[1]}
    )

    assert txn.events["TransferBatch"]["from"] == accounts[1]
    assert txn.events["TransferBatch"]["to"] == accounts[0]
    assert txn.events["TransferBatch"]["ids"] == erc1155ids
    assert txn.events["TransferBatch"]["values"] == [10e8, 10e8]

    toAssets = environment.notional.getAccountPortfolio(accounts[0])
    assert len(toAssets) == 2
    assert toAssets[0][0] == assets[0][0]
    assert toAssets[0][1] == assets[0][1]
    assert toAssets[0][2] == assets[0][2]
    assert toAssets[0][3] == 10e8

    assert toAssets[1][0] == assets[1][0]
    assert toAssets[1][1] == assets[1][1]
    assert toAssets[1][2] == assets[1][2]
    assert toAssets[1][3] == 10e8

    # Tests transfer to bitmap account
    environment.notional.safeBatchTransferFrom(
        accounts[1], accounts[2], erc1155ids, [10e8, 10e8], bytes(), {"from": accounts[1]}
    )
    toAssets = environment.notional.getAccountPortfolio(accounts[2])
    assert toAssets[0][0] == assets[0][0]
    assert toAssets[0][1] == assets[0][1]
    assert toAssets[0][2] == assets[0][2]
    assert toAssets[0][3] == 10e8

    assert toAssets[1][0] == assets[1][0]
    assert toAssets[1][1] == assets[1][1]
    assert toAssets[1][2] == assets[1][2]
    assert toAssets[1][3] == 10e8

    check_system_invariants(environment, accounts)


def test_transfer_has_fcash_failure(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5100e8,
        withdrawEntireCashBalance=True,
    )
    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    assets = environment.notional.getAccountPortfolio(accounts[1])
    erc1155id = environment.notional.encodeToId(assets[0][0], assets[0][1], assets[0][2])

    with brownie.reverts("Insufficient free collateral"):
        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 200e8, bytes(), {"from": accounts[1]}
        )


def test_transfer_has_liquidity_tokens(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        depositActionAmount=100e8,
    )

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    assets = environment.notional.getAccountPortfolio(accounts[1])
    erc1155id = environment.notional.encodeToId(assets[1][0], assets[1][1], assets[1][2])
    txn = environment.notional.safeTransferFrom(
        accounts[1], accounts[0], erc1155id, 10e8, bytes(), {"from": accounts[1]}
    )

    assert txn.events["TransferSingle"]["from"] == accounts[1]
    assert txn.events["TransferSingle"]["to"] == accounts[0]
    assert txn.events["TransferSingle"]["id"] == erc1155id
    assert txn.events["TransferSingle"]["value"] == 10e8

    toAssets = environment.notional.getAccountPortfolio(accounts[0])
    assert toAssets[0][0] == assets[1][0]
    assert toAssets[0][1] == assets[1][1]
    assert toAssets[0][2] == assets[1][2]
    assert toAssets[0][3] == 10e8

    check_system_invariants(environment, accounts)


def test_batch_transfer_has_liquidity_tokens(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 2,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            },
        ],
        depositActionAmount=200e8,
    )

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    assets = environment.notional.getAccountPortfolio(accounts[1])
    erc1155ids = [
        environment.notional.encodeToId(assets[1][0], assets[1][1], assets[1][2]),
        environment.notional.encodeToId(assets[3][0], assets[3][1], assets[3][2]),
    ]
    txn = environment.notional.safeBatchTransferFrom(
        accounts[1], accounts[0], erc1155ids, [10e8, 10e8], bytes(), {"from": accounts[1]}
    )

    assert txn.events["TransferBatch"]["from"] == accounts[1]
    assert txn.events["TransferBatch"]["to"] == accounts[0]
    assert txn.events["TransferBatch"]["ids"] == erc1155ids
    assert txn.events["TransferBatch"]["values"] == [10e8, 10e8]

    toAssets = environment.notional.getAccountPortfolio(accounts[0])
    assert len(toAssets) == 2
    assert toAssets[0][0] == assets[1][0]
    assert toAssets[0][1] == assets[1][1]
    assert toAssets[0][2] == assets[1][2]
    assert toAssets[0][3] == 10e8

    assert toAssets[1][0] == assets[3][0]
    assert toAssets[1][1] == assets[3][1]
    assert toAssets[1][2] == assets[3][2]
    assert toAssets[1][3] == 10e8

    check_system_invariants(environment, accounts)


def test_transfer_fail_liquidity_tokens(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [
            {
                "tradeActionType": "AddLiquidity",
                "marketIndex": 1,
                "notional": 100e8,
                "minSlippage": 0,
                "maxSlippage": 0.40 * RATE_PRECISION,
            }
        ],
        depositActionAmount=100e8,
    )

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    assets = environment.notional.getAccountPortfolio(accounts[1])
    erc1155id = environment.notional.encodeToId(assets[1][0], assets[1][1], assets[1][2])

    with brownie.reverts("dev: portfolio handler negative liquidity token balance"):
        # Fails balance check
        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 200e8, bytes(), {"from": accounts[1]}
        )

        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [200e8], bytes(), {"from": accounts[1]}
        )

    with brownie.reverts("Insufficient free collateral"):
        # Fails free collateral check
        environment.notional.safeTransferFrom(
            accounts[1], accounts[0], erc1155id, 100e8, bytes(), {"from": accounts[1]}
        )

        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[0], [erc1155id], [100e8], bytes(), {"from": accounts[1]}
        )

    with brownie.reverts("dev: invalid asset in set ifcash assets"):
        # Cannot transfer liquidity tokens to bitmap currency account
        environment.notional.safeTransferFrom(
            accounts[1], accounts[2], erc1155id, 10e8, bytes(), {"from": accounts[1]}
        )

        environment.notional.safeBatchTransferFrom(
            accounts[1], accounts[2], [erc1155id], [10e8], bytes(), {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts)


@pytest.mark.only
def test_transfer_borrow_fcash_deposit_collateral(environment, accounts):
    pass


@pytest.mark.only
def test_transfer_borrow_fcash_borrow_market(environment, accounts):
    pass


@pytest.mark.only
def test_transfer_borrow_fcash_redeem_ntoken(environment, accounts):
    pass