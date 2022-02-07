import json
from brownie import Contract

def loadContractFromArtifact(path, name, address):
    with open(path, "r") as a:
        artifact = json.load(a)
        return Contract.from_abi(name, address, abi=artifact["abi"])
    return None
