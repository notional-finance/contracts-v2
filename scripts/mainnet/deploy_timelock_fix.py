import json

from brownie import NoteERC20, accounts, network
from scripts.deployment import deployGovernance
from scripts.mainnet.deploy_governance import EnvironmentConfig, GovernanceConfig
from scripts.mainnet.deploy_notional import verify


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    networkName = network.show_active()

    output_file = "v2.{}.json".format(network.show_active())
    output = None
    with open(output_file, "r") as f:
        output = json.load(f)
    noteERC20 = NoteERC20.at(output["note"])

    # Deploying governance
    newGovernor = deployGovernance(
        deployer,
        noteERC20,
        EnvironmentConfig[networkName]["GuardianMultisig"],
        GovernanceConfig["governorConfig"],
    )
    print("Deployed Governor to {}".format(newGovernor.address))

    verify(
        newGovernor.address,
        [
            str(GovernanceConfig["governorConfig"]["quorumVotes"]),
            str(GovernanceConfig["governorConfig"]["proposalThreshold"]),
            str(GovernanceConfig["governorConfig"]["votingDelayBlocks"]),
            str(GovernanceConfig["governorConfig"]["votingPeriodBlocks"]),
            noteERC20.address,
            EnvironmentConfig[networkName]["GuardianMultisig"],
            str(GovernanceConfig["governorConfig"]["minDelay"]),
            str(0),
        ],
    )

    # Encoding for transfer of NOTE tokens to new governor
    # n = web3.eth.contract(abi=NoteERC20.abi)
    # n.encodeABI(fn_name="transfer", args=[newGovernor.address,
    #   noteERC20.balanceOf(governor.address)])
