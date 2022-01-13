from brownie import SettlementRateFix
from scripts.mainnet.upgrade_notional import full_upgrade, upgrade_checks

# Changes:
# contracts/external/Router.sol

# Bitmap Duplicate Currency Fix:
# contracts/external/actions/AccountAction.sol
#     - contracts/internal/AccountContextHandler.sol

# Transfer Ownership Change:
# contracts/external/actions/GovernanceAction.sol
#     - contracts/global/StorageLayoutV2.sol

# New Treasury Action:
# contracts/external/actions/TreasuryAction.sol
#     - contracts/global/StorageLayoutV2.sol
#     - contracts/internal/balances/BalanceHandler.sol

# New View Methods:
# contracts/external/Views.sol
#     - contracts/global/StorageLayoutV2.sol

# contracts/external/SettleAssetsExternal.sol
#     - contracts/internal/markets/AssetRate.sol
#     - contracts/internal/settlement/SettlePortfolioAssets.sol
#   - Dependencies:
#     - FreeCollateralExternal
#     - AccountAction
#     - BatchAction
#     - ERC1155Action
#     - nTokenAction
#     - nTokenRedeemAction
#     - nTokenMintAction
#     - TradingAction
#     - LiquidateCurrencyAction
#     - LiquidatefCashAction
#     - InitializeMarketsAction


def main():
    (deployer, output) = upgrade_checks()
    (router, pauseRouter, contracts) = full_upgrade(deployer)

    patchFix = SettlementRateFix.deploy(router.address, output["notional"], {"from": deployer})

    print("New Router Deployed at: {}".format(router.address))
    print("Patch Fix Deployed at : {}".format(patchFix.address))

    # To Complete Upgrade:
    #   1. Upgrade system to new router
    #   2. Transfer ownership (pending) to patch fix router
    #   3. Execute atomicPatchAndUpgrade() on patch fix router
