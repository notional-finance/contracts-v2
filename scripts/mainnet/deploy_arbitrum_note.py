# flake8: noqa
import json

from brownie import ArbitrumL1NoteERC20, ArbitrumL2NoteERC20, NoteERC20, accounts, network, nProxy
from scripts.mainnet.deploy_notional import verify

ARBITRUM_CONFIG = {
    "rinkeby": {
        "customGateway": "0x917dc9a69F65dC3082D518192cd3725E1Fa96cA2",
        "gatewayRouter": "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380",
    },
    "arbitrum-testnet": {
        "customGateway": "0x9b014455AcC2Fe90c52803849d0002aeEC184a06",
        "gatewayRouter": "0x9413AD42910c1eA60c737dB5f58d1C504498a3cD",
    },
}

# TODO: figure out these parameters...
# def getGasPrice():
#     network.gasPrice()

# def getMaxGas():
#     estimateRetryableTicket()

# def getMaxSubmissionCost():
#     getSubmissionPrice()


def deployL2():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = ARBITRUM_CONFIG[network.show_active()]
    address_file = "v2.{}.json".format(network.show_active())
    addresses = None
    with open(address_file, "r") as f:
        addresses = json.load(f)

    arbL2 = ArbitrumL2NoteERC20.deploy(
        config["customGateway"], addresses["note"], {"from": deployer}
    )

    # Sets the deployer as the owner
    initializeCallData = arbL2.initialize.encode_input([], [], deployer.address)
    proxy = nProxy.deploy(
        arbL2.address, initializeCallData, {"from": deployer}, publish_source=True
    )

    # verify(arbL2.address, [config["customGateway"], addresses["note"]])

    addresses["arbitrumNote"] = proxy.address
    with open(address_file, "w") as f:
        json.dump(f, addresses)


def deployL1():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = ARBITRUM_CONFIG[network.show_active()]
    arbL1 = ArbitrumL1NoteERC20.deploy(
        config["customGateway"], config["gatewayRouter"], {"from": deployer}
    )

    address_file = "v2.{}.json".format(network.show_active())
    addresses = None
    with open(address_file, "r") as f:
        addresses = json.load(f)

    # Upgrade NoteERC20 to arbitrum
    note = NoteERC20.at(addresses["note"])
    # TODO: needs to be called via owner
    # registerCallData = arbL1.registerTokenOnL2.encode_input(
    #     addresses["arbitrumNote"],
    #     maxSubmissionCostForCustomBridge,
    #     etc...
    # )
    # upgradeCallData = note.upgradeToAndCall.encode_input(arbL1.address, registerCallData)
