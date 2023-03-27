// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./AbstractSettingsRouter.sol";
import "../../external/SettleAssetsExternal.sol";
import "../../internal/pCash/PrimeCashExchangeRate.sol";
import "../../internal/pCash/PrimeRateLib.sol";

contract MockSettleAssets is AbstractSettingsRouter {
    /// @notice Emitted whenever an account context has updated
    event AccountContextUpdate(address indexed account);
    /// @notice Emitted when an account has assets that are settled
    event AccountSettled(address indexed account);

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    function settleAccount(address account) external returns (AccountContext memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext = SettleAssetsExternal.settleAccount(account, accountContext);
        AccountContextHandler.setAccountContext(accountContext, account);

        return accountContext;
    }

    function getSettlementRate(uint16 currencyId, uint256 maturity)
        external view returns (PrimeRate memory) {
        return PrimeRateLib.buildPrimeRateSettlementView(currencyId, maturity, block.timestamp);
    }
}
