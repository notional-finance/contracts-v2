// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/portfolio/PortfolioHandler.sol";
import "../internal/AccountContextHandler.sol";
import "../internal/Liquidation.sol";
import "../global/StorageLayoutV1.sol";

contract BaseMockLiquidation is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using Liquidation for LiquidationFactors;
    using Market for MarketParameters;

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setCashGroup(uint256 id, CashGroupParameterStorage calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(uint256 currencyId)
        public
        view
        returns (CashGroupParameters memory, MarketParameters[] memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        market.storageSlot = Market.getSlot(currencyId, settlementDate, market.maturity);
        // ensure that state gets set
        market.storageState = 0xFF;
        market.setMarketStorage();
    }

    function setETHRateMapping(uint256 id, ETHRateStorage calldata rs) external {
        underlyingToETHRateMapping[id] = rs;
    }

    function setPortfolio(address account, PortfolioAsset[] memory assets) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState =
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        portfolioState.newAssets = assets;
        accountContext.storeAssetsAndUpdateContext(account, portfolioState, false);
        accountContext.setAccountContext(account);
    }

    function setBalance(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 perpTokenBalance
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.setActiveCurrency(currencyId, true, Constants.ACTIVE_IN_BALANCES);
        accountContext.setAccountContext(account);

        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        bytes32 data =
            ((bytes32(uint256(perpTokenBalance))) |
                (bytes32(0) << 96) |
                (bytes32(cashBalance) << 128));

        assembly {
            sstore(slot, data)
        }
    }
}
