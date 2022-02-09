import json
import re
from brownie import Contract

TokenType = {
    "UnderlyingToken": 0,
    "cToken": 1,
    "cETH": 2,
    "Ether": 3,
    "NonMintable": 4,
    "aToken": 5,
}

def loadContractFromABI(name, address, path):
    with open(path, "r") as f:
        abi = json.load(f)
    return Contract.from_abi(name, address, abi)

def loadContractFromArtifact(name, address, path):
    with open(path, "r") as a:
        artifact = json.load(a)
    return Contract.from_abi(name, address, artifact["abi"])

def getDependencies(bytecode):
    deps = set()
    for marker in re.findall("_{1,}[^_]*_{1,}", bytecode):
        library = marker.strip("_")
        deps.add(library)
    return list(deps)

def isMainnet(network):
    return network == "mainnet" or network == "hardhat-fork"

def hasTransferFee(symbol):
    return symbol == "USDT"
