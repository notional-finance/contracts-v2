import json
import re
from brownie import Contract
from brownie.convert.datatypes import HexString

TokenType = {
    "UnderlyingToken": 0,
    "cToken": 1,
    "cETH": 2,
    "Ether": 3,
    "NonMintable": 4,
    "aToken": 5,
}

CurrencyId = {
    "ETH": 1,
    "DAI": 2,
    "USDC": 3,
    "WBTC": 4
}

CurrencySymbol = {
    1: "ETH",
    2: "DAI",
    3: "USDC",
    4: "WBTC"
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
    result = list(deps)
    result.sort()
    return result

def encodeNTokenParams(config):
    return HexString("0x{}{}{}{}{}".format(
        hex(config[4])[2:],
        hex(config[3])[2:],
        hex(config[2])[2:],
        hex(config[1])[2:],
        hex(config[0])[2:]
    ), "bytes5")

def isProduction(network):
    return network == "mainnet" or network == "hardhat-fork"

def hasTransferFee(symbol):
    return symbol == "USDT"
