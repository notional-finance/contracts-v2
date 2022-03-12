from brownie import NotionalV21PatchFix
from scripts.mainnet.upgrade_notional import full_upgrade, upgrade_checks


def main():
    (deployer, output) = upgrade_checks()
    (router, pauseRouter, contracts) = full_upgrade(deployer)

    patchFix = NotionalV21PatchFix.deploy(router.address, output["notional"], {"from": deployer})

    print("New Router Deployed at: {}".format(router.address))
    print("Patch Fix Deployed at : {}".format(patchFix.address))

    # To Complete Upgrade:
    #   1. Upgrade system to new router
    #   2. Transfer ownership (pending) to patch fix router
    #   3. Execute atomicPatchAndUpgrade() on patch fix router
