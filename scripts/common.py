import json
from brownie import Contract

def loadContractFromArtifact(path, name, address):
    with open(path, "r") as a:
        artifact = json.load(a)
    return Contract.from_abi(name, address, abi=artifact["abi"])

class ContractDeployer:
    def __init__(self, context, deployer) -> None:
        self.context = context
        self.deployer = deployer

    def deploy(self, name, contract, args):
        if name in self.context:
            print("{} deployed at {}".format(name, self.context[name]))
        else:
            try:
                print("Deploying {}".format(name))
                lib = contract.deploy(*args, {"from": self.deployer})
                self.context[name] = lib.address
            except Exception as e:
                print("Failed to deploy {}: {}".format(name, e))
