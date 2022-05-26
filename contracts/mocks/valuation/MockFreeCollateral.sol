// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/valuation/FreeCollateral.sol";
import "./MockValuationLib.sol";

contract MockFreeCollateral is MockValuationBase {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using Market for MarketParameters;
    event Liquidation(LiquidationFactors factors);
    event FreeCollateralResult(int256 fc, int256[] netLocal);
    event AccountContextUpdate(address indexed account);

    function getNetCashGroupValue(
        PortfolioAsset[] memory assets,
        uint256 blockTime,
        uint256 portfolioIndex
    ) external view returns (int256, uint256) {
        uint16 currencyId = uint16(assets[portfolioIndex].currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        return AssetHandler.getNetCashGroupValue(
            assets,
            cashGroup,
            market,
            blockTime,
            portfolioIndex
        );
    }

    function getFreeCollateralView(address account, uint256 blockTime)
        external
        view
        returns (int256, int256[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }

    function getFreeCollateralStateful(address account, uint256 blockTime)
        external
        returns (int256, bool)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (int256 ethFC, bool updateContext) = FreeCollateral.getFreeCollateralStateful(account, accountContext, blockTime);
        if (updateContext) accountContext.setAccountContext(account);

        return (ethFC, updateContext);
    }

    function getLiquidationFactors(
        address account,
        uint256 blockTime,
        uint256 localCurrencyId,
        uint256 collateralCurrencyId
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (LiquidationFactors memory factors, /* */) = FreeCollateral.getLiquidationFactors(
            account, accountContext, blockTime, localCurrencyId, collateralCurrencyId);
        emit Liquidation(factors);
    }

    function testFreeCollateral(address account, uint256 blockTime)
        external
        returns (int256, int256[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (int256 fcView, int256[] memory netLocal) =
            FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);

        AccountContext memory accountContextNew =
            AccountContextHandler.getAccountContext(account);

        // prettier-ignore
        (int256 ethDenominatedFC, bool updateContext) =
            FreeCollateral.getFreeCollateralStateful(account, accountContextNew, blockTime);

        if (updateContext) {
            accountContextNew.setAccountContext(account);
        }

        assert(fcView == ethDenominatedFC);

        if (fcView < 0) {
            (LiquidationFactors memory factors, /* */) = FreeCollateral.getLiquidationFactors(
                account, accountContext, blockTime, 1, 0);
            emit Liquidation(factors);

            assert(fcView == factors.netETHValue);
        }

        emit FreeCollateralResult(fcView, netLocal);
        return (fcView, netLocal);
    }
}
