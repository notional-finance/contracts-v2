import json
import os

from brownie import accounts, network
from brownie.convert.datatypes import Wei
from brownie.network.contract import Contract
from scripts.deployment import deployGovernance, deployNoteERC20

GovernanceConfig = {
    "initialBalances": {
        "GovernorAlpha": Wei(50_000_000e8),
        "Airdrop": Wei(749_990e8),
        "NotionalInc": Wei(49_250_010e8),
    },
    # Governance config values mirror current Compound governance parameters
    "governorConfig": {
        "quorumVotes": Wei(4_000_000e8),  # 4% of total supply
        "proposalThreshold": Wei(650_000e8),  # 0.65% of total supply
        "votingDelayBlocks": 13140,  # ~2 days
        "votingPeriodBlocks": 19710,  # ~3 days
        "minDelay": 86400 * 2,  # 2 Days
    },
}


def deployAirdropContract(deployer, token):
    MerkleDistributor = json.load(
        open(os.path.join(os.path.dirname(__file__), "MerkleDistributor.json"), "r")
    )
    AirdropMerkleTree = json.load(
        open(os.path.join(os.path.dirname(__file__), "AirdropMerkleTree.json"), "r")
    )

    AirdropContract = network.web3.eth.contract(
        abi=MerkleDistributor["abi"], bytecode=MerkleDistributor["bytecode"]
    )
    txn = AirdropContract.constructor(
        token.address, AirdropMerkleTree["merkleRoot"], int(os.environ["AIRDROP_CLAIM_TIME"])
    ).buildTransaction({"from": deployer.address, "nonce": deployer.nonce})
    signed_txn = network.web3.eth.account.sign_transaction(txn, deployer.private_key)
    sent_txn = network.web3.eth.send_raw_transaction(signed_txn.rawTransaction)
    tx_receipt = network.web3.eth.wait_for_transaction_receipt(sent_txn)
    print("Deployed airdrop contract to {}".format(tx_receipt.contractAddress))

    return Contract.from_abi("Airdrop", tx_receipt.contractAddress, abi=MerkleDistributor["abi"])


def main():
    # Load the deployment address
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    startBlock = network.chain.height
    if network.show_active() == "development":
        accounts[0].transfer(deployer, 100e18)

    print("Loaded deployment account at {}".format(deployer.address))
    print("Deploying to {}".format(network.show_active()))

    # Deploying NOTE token
    (noteERC20Proxy, noteERC20) = deployNoteERC20(deployer)
    print("Deployed NOTE token to {}".format(noteERC20.address))

    # Deploying airdrop contract
    airdrop = deployAirdropContract(deployer, noteERC20)

    # Deploying governance
    governor = deployGovernance(
        deployer,
        noteERC20,
        os.environ["GUARDIAN_MULTISIG_ADDRESS"],
        GovernanceConfig["governorConfig"],
    )
    print("Deployed Governor to {}".format(governor.address))

    # Initialize NOTE token balances
    initialAddresses = [governor.address, airdrop.address, os.environ["NOTIONAL_INC_ADDRESS"]]
    initialBalances = [
        GovernanceConfig["initialBalances"]["GovernorAlpha"],
        GovernanceConfig["initialBalances"]["Airdrop"],
        GovernanceConfig["initialBalances"]["NotionalInc"],
    ]

    txn = noteERC20.initialize(
        initialAddresses,
        initialBalances,
        # The owner of the token will be set to the multisig initially
        os.environ["GUARDIAN_MULTISIG_ADDRESS"],
        {"from": deployer},
    )
    print("NOTE token initialized with balances to accounts:")
    for t in txn.events["Transfer"]:
        print(
            "from: {}, to: {}, formatted amount: {}".format(
                t["from"], t["to"], (t["amount"] / 10 ** 8)
            )
        )

        assert noteERC20.balanceOf(t["to"]) == t["amount"]

    print("Current NOTE token owner is {}".format(noteERC20.owner()))

    # Save outputs here
    output_file = "v2.{}.json".format(network.show_active())
    with open(output_file, "w") as f:
        json.dump(
            {
                "chainId": network.chain.id,
                "networkName": network.show_active(),
                "airdrop": airdrop.address,
                "deployer": deployer.address,
                "guardian": os.environ["GUARDIAN_MULTISIG_ADDRESS"],
                "governor": governor.address,
                "note": noteERC20.address,
                "startBlock": startBlock,
            },
            f,
            sort_keys=True,
            indent=4,
        )
