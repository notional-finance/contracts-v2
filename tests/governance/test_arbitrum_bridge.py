import brownie
import pytest
from brownie import ArbitrumL2NoteERC20, Contract, nProxy


@pytest.fixture(scope="module", autouse=True)
def arbNote(accounts):
    impl = ArbitrumL2NoteERC20.deploy(accounts[0], accounts[1], {"from": accounts[0]})
    noteERC20Proxy = nProxy.deploy(impl.address, bytes(), {"from": accounts[0]})
    return Contract.from_abi("ArbNoteERC20", noteERC20Proxy.address, abi=ArbitrumL2NoteERC20.abi)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_initialize(arbNote, accounts):
    txn = arbNote.initialize([accounts[1]], [100e8], accounts[0], {"from": accounts[0]})
    assert len(txn.events.keys()) == 0
    assert arbNote.owner() == accounts[0].address


def test_upgrade(arbNote, accounts):
    arbNote.initialize([], [], accounts[0], {"from": accounts[0]})
    assert arbNote.l2Gateway() == accounts[0]
    impl2 = ArbitrumL2NoteERC20.deploy(accounts[2], accounts[3], {"from": accounts[0]})
    arbNote.upgradeTo(impl2, {"from": accounts[0]})
    assert arbNote.l2Gateway() == accounts[2]


def test_bridge_fail_auth(arbNote, accounts):
    with brownie.reverts("ONLY_l2GATEWAY"):
        arbNote.bridgeMint(accounts[1], 100e8, {"from": accounts[1]})
        arbNote.bridgeBurn(accounts[1], 100e8, {"from": accounts[1]})


def test_bridge_mint_and_burn(arbNote, accounts):
    arbNote.bridgeMint(accounts[1], 100e8, {"from": accounts[0]})
    assert arbNote.balanceOf(accounts[1]) == 100e8
    assert arbNote.arbitrumTotalSupply() == 100e8

    arbNote.delegate(accounts[1], {"from": accounts[1]})
    assert arbNote.getCurrentVotes(accounts[1]) == 100e8

    arbNote.bridgeMint(accounts[1], 100e8, {"from": accounts[0]})
    assert arbNote.balanceOf(accounts[1]) == 200e8
    assert arbNote.arbitrumTotalSupply() == 200e8
    assert arbNote.getCurrentVotes(accounts[1]) == 200e8

    arbNote.bridgeBurn(accounts[1], 25e8, {"from": accounts[0]})
    assert arbNote.balanceOf(accounts[1]) == 175e8
    assert arbNote.arbitrumTotalSupply() == 175e8
    assert arbNote.getCurrentVotes(accounts[1]) == 175e8
