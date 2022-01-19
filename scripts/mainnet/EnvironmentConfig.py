import json

from brownie import MockERC20, accounts
from brownie.network.contract import Contract
from brownie.project import ContractsV2Project

with open("scripts/compound_artifacts/nComptroller.json", "r") as a:
    Comptroller = json.load(a)

with open("scripts/compound_artifacts/nCErc20.json") as a:
    cToken = json.load(a)

with open("scripts/compound_artifacts/nCEther.json") as a:
    cEther = json.load(a)

NotionalABI = ContractsV2Project._build.get("NotionalProxy")["abi"]
LendingPoolABI = ContractsV2Project._build.get("ILendingPool")["abi"]
aTokenABI = ContractsV2Project._build.get("IAToken")["abi"]

ETH_ADDRESS = "0x0000000000000000000000000000000000000000"


class Environment:
    def __init__(self) -> None:
        self.notional = Contract.from_abi(
            "Notional", "0x1344a36a1b56144c3bc62e7757377d288fde0369", NotionalABI
        )
        self.tokens = {
            "NOTE": Contract.from_abi(
                "ERC20", "0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5", MockERC20.abi
            ),
            "WETH": Contract.from_abi(
                "ERC20", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", MockERC20.abi
            ),
            "USDC": Contract.from_abi(
                "ERC20", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", MockERC20.abi
            ),
            "DAI": Contract.from_abi(
                "ERC20", "0x6b175474e89094c44da98b954eedeac495271d0f", MockERC20.abi
            ),
            "WBTC": Contract.from_abi(
                "ERC20", "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599", MockERC20.abi
            ),
            "LINK": Contract.from_abi(
                "ERC20", "0x514910771af9ca656af840dff83e8264ecf986ca", MockERC20.abi
            ),
            "COMP": Contract.from_abi(
                "ERC20", "0xc00e94cb662c3520282e6f5717214004a7f26888", MockERC20.abi
            ),
            "AAVE": Contract.from_abi(
                "ERC20", "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9", MockERC20.abi
            ),
            "cDAI": Contract.from_abi(
                "cToken", "0x5d3a536e4d6dbd6114cc1ead35777bab948e3643", cToken["abi"]
            ),
            "cUSDC": Contract.from_abi(
                "cToken", "0x39aa39c021dfbae8fac545936693ac917d5e7563", cToken["abi"]
            ),
            "cWBTC": Contract.from_abi(
                "cToken", "0xccf4429db6322d5c611ee964527d42e5d685dd6a", cToken["abi"]
            ),
            "cETH": Contract.from_abi(
                "cEther", "0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5", cEther["abi"]
            ),
            "aDAI": Contract.from_abi(
                "aToken", "0x028171bCA77440897B824Ca71D1c56caC55b68A3", aTokenABI
            ),
            "aUSDC": Contract.from_abi(
                "aToken", "0xBcca60bB61934080951369a648Fb03DF4F96263C", aTokenABI
            ),
            "aWETH": Contract.from_abi(
                "aToken", "0x030bA81f1c18d280636F32af80b9AAd02Cf0854e", aTokenABI
            ),
            "aLINK": Contract.from_abi(
                "aToken", "0xa06bC25B5805d5F8d82847D191Cb4Af5A3e873E0", aTokenABI
            ),
        }

        self.compound = {
            "Comptroller": Contract.from_abi(
                "Comptroller", "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b", Comptroller["abi"]
            )
        }

        self.aave = {
            "LendingPool": Contract.from_abi(
                "LendingPool", "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9", LendingPoolABI
            )
        }

        self.whales = {
            "DAI": accounts.at("0x6dfaf865a93d3b0b5cfd1b4db192d1505676645b", force=True),
            "cDAI": accounts.at("0x33b890d6574172e93e58528cd99123a88c0756e9", force=True),
            "ETH": accounts.at("0x7D24796f7dDB17d73e8B1d0A3bbD103FBA2cb2FE", force=True),
            "cETH": accounts.at("0x1a1cd9c606727a7400bb2da6e4d5c70db5b4cade", force=True),
            "NOTE": accounts.at("0x22341fB5D92D3d801144aA5A925F401A91418A05", force=True),
        }

        self.deployer = accounts.at("0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3", force=True)
        self.owner = accounts.at(self.notional.owner(), force=True)


def getEnvironment():
    return Environment()
