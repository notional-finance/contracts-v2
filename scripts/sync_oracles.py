from brownie import MockAggregator, accounts, network


def main():
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    daiETH = MockAggregator.at("0x990de64bb3e1b6d99b1b50567fc9ccc0b9891a4d")
    usdcETH = MockAggregator.at("0x0988059af97c65d6a6eb8aca422784728d907406")
    btcETH = MockAggregator.at("0x0cb9a95789929dc75d1b77a916762bc719305543")

    daiETH.setAnswer(321777127058284, {"from": deployer})
    usdcETH.setAnswer(321660988141906, {"from": deployer})
    btcETH.setAnswer(13268329197480519171, {"from": deployer})
