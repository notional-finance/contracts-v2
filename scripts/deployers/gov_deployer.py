import json

from brownie import accounts, network, NoteERC20, nProxy, GovernorAlpha
from scripts.deployment import deployArtifact
# TODO: refactor config definitions
from scripts.mainnet.deploy_governance import EnvironmentConfig, GovernanceConfig
from scripts.common import ContractDeployer

class GovDeployer:
    def __init__(self, network, deployer) -> None:
        self.config = {}
        self.airdrop = None
        self.governor = None
        self.noteERC20 = None
        self.network = network
        self.deployer = deployer

    def deployNOTE(self):
        # These two lines ensure that the note token is deployed to the correct address
        # every time.
        if network.show_active() == "sandbox":
            deployer = accounts.load("DEVELOPMENT_DEPLOYER")
            accounts[0].transfer(deployer, 100e18)
        elif network.show_active() == "development" or network.show_active() == "hardhat":
            deployer = "0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3"

        if "noteERC20Impl" in self.config:
            print("noteERC20Impl deployed at {}".format(self.config["noteERC20Impl"]))
            return

        deployer = ContractDeployer(self.deployer, self.config)
        # Deploy NOTE implementation contract
        deployer.deploy("noteERC20Impl", NoteERC20, [])
        # This is a proxied ERC20
        deployer.deploy("noteERC20", nProxy, [self.config["noteERC20Impl"], bytes()])

    def deployGovernor(self):
        if "noteERC20" not in self.config:
            self.deployNOTE()

        governorConfig = GovernanceConfig["governorConfig"]
        guardian = EnvironmentConfig[self.network]["GuardianMultisig"]
        deployer = ContractDeployer(self.deployer, self.config)
        deployer.deploy("governor", GovernorAlpha, [
            governorConfig["quorumVotes"],
            governorConfig["proposalThreshold"],
            governorConfig["votingDelayBlocks"],
            governorConfig["votingPeriodBlocks"],
            self.config["noteERC20"],
            guardian,
            governorConfig["minDelay"],
            0,
        ])

    def deployAirdrop(self):
        AirdropMerkleTree = json.load(
            open("scripts/mainnet/AirdropMerkleTree.json", "r")
        )

        if "airdrop" in self.config:
            print("Airdrop deployed at {}".format(self.config["airdrop"]))
            return

        # Depends on NOTE
        if "noteERC20" not in self.config:
            self.deployNOTE()

        airdrop = deployArtifact(
            "scripts/mainnet/MerkleDistributor.json",
            [
                self.config["noteERC20"],
                AirdropMerkleTree["merkleRoot"],
                EnvironmentConfig[self.network]["AirdropClaimTime"],
            ],
            self.deployer,
            "AirdropContract",
        )
        print("Deployed airdrop contract to {}".format(airdrop.address))
        self.config["airdrop"] = airdrop.address

        return airdrop

    def load(self):
        print("Loading governance config")
        with open("v2.{}.json".format(self.network), "r") as f:
            self.config = json.load(f)
        if "airdrop" in self.config:
            self.airdrop = self.config["airdrop"]
        if "governor" in self.config:
            self.governor = self.config["governor"]
        if "noteERC20" in self.config:
            self.noteERC20 = self.config["noteERC20"]

    def save(self):
        print("Saving governance config")
        self.config["chainId"] = network.chain.id
        self.config["networkName"] = network.show_active()
        if self.airdrop != None:
            self.config["airdrop"] = self.airdrop
        self.config["deployer"] = self.deployer.address
        self.config["guardian"] = EnvironmentConfig[self.network]["GuardianMultisig"]
        if self.governor != None:
            self.config["governor"] = self.governor
        if self.noteERC20 != None:
            self.config["note"] = self.noteERC20
        self.config["startBlock"] = network.chain.height
        with open("v2.{}.json".format(self.network), "w") as f:
            json.dump(self.config, f, sort_keys=True, indent=4)

def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    gov = GovDeployer(network.show_active(), deployer)
    gov.load()
    gov.deployNOTE()
    gov.deployAirdrop()
    gov.deployGovernor()
    gov.save()
