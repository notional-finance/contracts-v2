import json
import re
import os
from brownie import Contract, network, project, convert

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
    
class ContractDeployer:
    def __init__(self, deployer, context={}, libs={}) -> None:
        self.project = project.ContractsVPrivateProject
        self.context = context
        self.deployer = deployer
        self.libs = libs

    def deploy(self, contract, args=[], name="", verify=False, singleton=False, isLib=False):
        c = None
        if name == "":
            name = contract._name
        if name in self.context:
            print("{} deployed at {}".format(name, self.context[name]))
            c = Contract.from_abi(name, self.context[name], abi=contract.abi)
        else:
            # Deploy libraries
            libs = getDependencies(contract.bytecode)
            deployed = []
            for lib in libs:
                deployed.append(self.deploy(self.project.dict()[lib], [], "", False, True, True))

            # Deploy contract
            try:
                print("Deploying {}".format(name))
                c = contract.deploy(*args, {"from": self.deployer}, publish_source=verify)
                self.context[name] = c.address
            except Exception as e:
                print("Failed to deploy {}: {}".format(name, e))

            # Verify libs
            if not isLib and len(deployed) > 0:
                addr = []
                if hasattr(c, "getLibInfo") and callable(getattr(c, "getLibInfo")):
                    info = c.getLibInfo()
                    if type(info) is convert.datatypes.ReturnValue:
                        addr = list(info)
                    elif type(info) is convert.datatypes.EthAddress:
                        addr.append(info)
                else:
                    raise Exception("Cannot verify libs, getLibInfo() not found on {}".format(name))

                if len(addr) != len(deployed):
                    raise Exception("getLibInfo(): incorrect length")
                for i, item in enumerate(deployed):
                    if (addr[i] != item.address):
                        raise Exception("Library mismatch! expected = {}, actual = {}".format(item.address, addr[i]))

        # Make sure there is only 1 copy in map.json (for libraries)
        if singleton:
            map = None
            with open("build/deployments/map.json", "r") as f:
                map = json.load(f)
            contracts = map[str(network.chain.id)]
            if name in contracts:
                deployments = contracts[name]
                for d in deployments:
                    f = "build/deployments/{}/{}.json".format(network.chain.id, d)
                    if d != c.address and os.path.exists(f):
                        os.remove(f)
                contracts[name] = [c.address]
            with open("build/deployments/map.json", "w") as f:
                json.dump(map, f, sort_keys=True, indent=4)        
        return c

        