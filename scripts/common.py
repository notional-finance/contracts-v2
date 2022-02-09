import json
import re
from brownie import Contract

def loadContractFromArtifact(path, name, address):
    with open(path, "r") as a:
        artifact = json.load(a)
    return Contract.from_abi(name, address, abi=artifact["abi"])

def getDependencies(bytecode):
    deps = set()
    for marker in re.findall("_{1,}[^_]*_{1,}", bytecode):
        library = marker.strip("_")
        deps.add(library)
    return list(deps)

def isMainnet(network):
    return network == "mainnet" or network == "hardhat-fork"
