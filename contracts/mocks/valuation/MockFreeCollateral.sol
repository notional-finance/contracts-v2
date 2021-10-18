// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "../../internal/valuation/FreeCollateral.sol";
import "./MockValuationLib.sol";

contract MockFreeCollateral is MockValuationBase {
    using UserDefinedType for IU;
    using UserDefinedType for IA;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using Market for MarketParameters;
    event Liquidation(LiquidationFactors factors);
    event FreeCollateralResult(IU fc, IA[] netLocal);
    event AccountContextUpdate(address indexed account);

    function getNetCashGroupValue(
        PortfolioAsset[] memory assets,
        uint256 blockTime,
        uint256 portfolioIndex
    ) external view returns (IA, uint256) {
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
        returns (IU, IA[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }

    function getFreeCollateralStateful(address account, uint256 blockTime)
        external
        returns (IU, bool)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (IU ethFC, bool updateContext) = FreeCollateral.getFreeCollateralStateful(account, accountContext, blockTime);
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
        returns (IU, IA[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (IU fcView, IA[] memory netLocal) =
            FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);

        AccountContext memory accountContextNew =
            AccountContextHandler.getAccountContext(account);

        // prettier-ignore
        (IU ethDenominatedFC, bool updateContext) =
            FreeCollateral.getFreeCollateralStateful(account, accountContextNew, blockTime);

        if (updateContext) {
            accountContextNew.setAccountContext(account);
        }

        assert(fcView.eq(ethDenominatedFC));

        if (fcView.isNegNotZero()) {
            (LiquidationFactors memory factors, /* */) = FreeCollateral.getLiquidationFactors(
                account, accountContext, blockTime, 1, 0);
            emit Liquidation(factors);

            assert(fcView.eq(factors.netETHValue));
        }

        emit FreeCollateralResult(fcView, netLocal);
        return (fcView, netLocal);
    }
}
