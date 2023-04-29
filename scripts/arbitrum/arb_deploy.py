from brownie import ZERO_ADDRESS, accounts, UnderlyingHoldingsOracle, ChainlinkAdapter, EmptyProxy, nProxy, UpgradeableBeacon
from scripts.arbitrum.arb_config import ListedOrder, ListedTokens
from scripts.common import TokenType

def deploy_note_proxy(deployer, owner):
    assert deployer.address == "0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3"
    impl = EmptyProxy.deploy(owner, {"from": deployer})
    # Must be nonce = 1
    # https://etherscan.io/tx/0xcd23bcecfef5de7afcc76d32350055de906d3394fcf1d35f3490a7c62926cb64
    return nProxy.deploy(impl, bytes(), {"from": deployer})

def deploy_notional_proxy(deployer, owner):
    assert deployer.address == "0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3"

    impl = EmptyProxy.deploy(owner, {"from": deployer})
    # Must be nonce = 28
    # https://etherscan.io/tx/0xd1334bf8efcbc152b3e8de40887f534171a9993082e8b4d6187bd6271e7ac0b9
    return nProxy.deploy(impl.address, bytes(), {"from": deployer})

def deploy_beacons(deployer, owner):
    assert deployer.address == "0x0000000000000000000000000000000000000000"

    impl = EmptyProxy.deploy(owner, {"from": deployer})
    nTokenBeacon = UpgradeableBeacon.deploy(impl, {"from": deployer})
    pCashBeacon = UpgradeableBeacon.deploy(impl, {"from": deployer})
    pDebtBeacon = UpgradeableBeacon.deploy(impl, {"from": deployer})
    wfCashBeacon = UpgradeableBeacon.deploy(impl, {"from": deployer})

    return ( nTokenBeacon, pCashBeacon, pDebtBeacon, wfCashBeacon )

def list_currency(symbol, notional, deployer):
    pCashOracle = _deploy_pcash_oracle(symbol, notional, deployer)
    ethOracle = _deploy_chainlink_oracle(symbol, deployer)
    _list_currency(symbol, notional, deployer, pCashOracle, ethOracle)

def _deploy_pcash_oracle(symbol, notional, deployer):
    token = ListedTokens[symbol]
    return UnderlyingHoldingsOracle(notional.address, token['address'], {"from": deployer})

def _deploy_chainlink_oracle(symbol, deployer):
    token = ListedTokens[symbol]
    if symbol == "ETH":
        return ZERO_ADDRESS
    else:
        return ChainlinkAdapter(
            token['baseOracle'],
            token['quoteOracle'],
            "Notional {} Chainlink Adapter".format(symbol),
            {"from": deployer}
        )

def _to_interest_rate_curve(params):
    return (
        params["kinkUtilization1"],
        params["kinkUtilization2"],
        params["kinkRate1"],
        params["kinkRate2"],
        params["maxRate25BPS"],
        params["minFeeRate5BPS"],
        params["maxFeeRate25BPS"],
        params["feeRatePercent"],
    )

def _list_currency(symbol, notional, deployer, pCashOracle, ethOracle):
    token = ListedTokens[symbol]

    txn = notional.listCurrency(
        (
            token['address'],
            False,
            TokenType["UnderlyingToken"] if symbol != "ETH" else TokenType["Ether"],
            token['decimals'],
            0,
        ),
        (
            ethOracle,
            18,
            False,
            token["buffer"],
            token["haircut"],
            token["liquidationDiscount"],
        ),
        _to_interest_rate_curve(token['primeCashCurve']),
        pCashOracle,
        True,  # allowDebt
        token['primeRateOracleTimeWindow5Min'],
        symbol,
        token['name'],
        {"from": deployer}
    )
    currencyId = txn.events["ListCurrency"]["newCurrencyId"]

    notional.enableCashGroup(
        currencyId,
        (
            token["maxMarketIndex"],
            token["rateOracleTimeWindow"],
            token["maxDiscountFactor"],
            token["reserveFeeShare"],
            token["debtBuffer"],
            token["fCashHaircut"],
            token["minOracleRate"],
            token["liquidationfCashDiscount"],
            token["liquidationDebtBuffer"],
            token["maxOracleRate"]
        ),
        token['name'],
        symbol,
        {"from": deployer}
    )

    notional.updateInterestRateCurve(
        currencyId,
        [1, 2],
        [_to_interest_rate_curve(token['fCashCurves'][0], token['fCashCurves'][1])],
        {"from": deployer}
    )

    notional.updateDepositParameters(currencyId, token['depositShare'], token['leverageThreshold'], {"from": deployer})

    notional.updateInitializationParameters(currencyId, [0, 0], token['proportion'], {"from": deployer})

    notional.updateTokenCollateralParameters(
        currencyId,
        token["residualPurchaseIncentive"],
        token["pvHaircutPercentage"],
        token["residualPurchaseTimeBufferHours"],
        token["cashWithholdingBuffer10BPS"],
        token["liquidationHaircutPercentage"],
        {"from": deployer}
    )

    notional.setMaxUnderlyingSupply(currencyId, token['maxUnderlyingSupply'], {"from": deployer})

def main():
    deployer = accounts.load("MAINNET_DEPLOYER")
    beaconDeployer = accounts.load("BEACON_DEPLOYER")
    fundingAccount = accounts.at("0x7d7935EDd4b6cDB5f34B0E1cCEAF85a3C4A11254", force=True)

    owner = '0x00'
    deploy_note_proxy(deployer, owner)
    notional = deploy_notional_proxy(deployer, owner)
    beacons = deploy_beacons(beaconDeployer, owner)

    # router = deploy_notional_router(deployer, notional)
    # notional.upgradeTo(router, {"from": deployer})
    # TODO: transfer tokens into the notional proxy

    for c in ListedOrder:
        list_currency(c, notional, deployer)