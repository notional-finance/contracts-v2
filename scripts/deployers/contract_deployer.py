import json
import os
from brownie import Contract, network, project, convert
from scripts.common import getDependencies

class ContractDeployer:
    def __init__(self, deployer, context=None, libs=None) -> None:
        self.project = project.ContractsV2Project
        self.deployer = deployer
        self.context = context
        if self.context == None:
            self.context = {}
        self.libs = libs
        if self.libs == None:
            self.libs = {}

    def deploy(self, contract, args=None, name="", verify=False, isLib=False):
        c = None
        if name == "":
            name = contract._name

        if args == None:
            args = []
        else:
            print(args)

        context = self.context
        if isLib:
            # If we are deploying a library, check if it's already deployed
            context = self.libs

        print(context)

        if name in context:
            print("{} deployed at {}".format(name, context[name]))
            c = Contract.from_abi(name, context[name], abi=contract.abi)
        else:
            # Deploy libraries
            deps = getDependencies(contract.bytecode)
            libs = []
            for dep in deps:
                libs.append(self.deploy(self.project.dict()[dep], [], "", False, True))

            # Deploy contract
            print("Deploying {}".format(name))
            c = contract.deploy(*args, {"from": self.deployer}, publish_source=False)
            if isLib:
                self.libs[name] = c.address
            else:
                self.context[name] = c.address

            # Verify libs
            if not isLib and len(libs) > 0:
                addr = []
                if hasattr(c, "getLibInfo") and callable(getattr(c, "getLibInfo")):
                    info = c.getLibInfo()
                    if type(info) is convert.datatypes.ReturnValue:
                        addr = list(info)
                    elif type(info) is convert.datatypes.EthAddress:
                        addr.append(info)
                else:
                    raise Exception("Cannot verify libs, getLibInfo() not found on {}".format(name))
                
                if len(addr) != len(libs):
                    raise Exception("getLibInfo(): incorrect length")
                for i, item in enumerate(libs):
                    if item.address not in addr[i]:
                        raise Exception("Library {} mismatch! expected = {}, actual = {}".format(
                            deps[i], 
                            item.address, 
                            addr[i]
                        ))

        # Make sure there is only 1 copy in map.json (for libraries)
        if isLib:
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
