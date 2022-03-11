// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./actions/nTokenMintAction.sol";
import "../internal/balances/TokenHandler.sol";
import "../global/StorageLayoutV1.sol";
import "../internal/markets/CashGroup.sol";
import "../internal/markets/AssetRate.sol";
import "../internal/nToken/nTokenSupply.sol";
import "../internal/nToken/nTokenHandler.sol";
import "../math/SafeInt256.sol";
import "../../interfaces/notional/NotionalCalculations.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract CalculationViews is StorageLayoutV1, NotionalCalculations {
    using TokenHandler for Token;
    using Market for MarketParameters;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;
    using nTokenHandler for nTokenPortfolio;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    function _checkValidCurrency(uint16 currencyId) internal view {
        require(0 < currencyId && currencyId <= maxCurrencyId, "Invalid currency id");
    }

    /** General Calculation View Methods **/

    /// @notice Returns the nTokens that will be minted when some amount of asset tokens are deposited
    function calculateNTokensToMint(uint16 currencyId, uint88 amountToDepositExternalPrecision)
        external
        view
        override
        returns (uint256)
    {
        _checkValidCurrency(currencyId);
        Token memory token = TokenHandler.getAssetToken(currencyId);
        int256 amountToDepositInternal =
            token.convertToInternal(int256(amountToDepositExternalPrecision));
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);

        int256 tokensToMint = nTokenMintAction.calculateTokensToMint(
            nToken,
            amountToDepositInternal,
            block.timestamp
        );

        return SafeCast.toUint256(tokensToMint);
    }

    /// @notice Returns the fCash amount to send when given a cash amount, be sure to buffer these amounts
    /// slightly because the liquidity curve is sensitive to changes in block time
    function getfCashAmountGivenCashAmount(
        uint16 currencyId,
        int88 netCashToAccount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view override returns (int256) {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Invalid block time");
        uint256 timeToMaturity = market.maturity - blockTime;
        (int256 rateScalar, int256 totalCashUnderlying, int256 rateAnchor) =
            Market.getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);
        int256 fee = Market.getExchangeRateFromImpliedRate(cashGroup.getTotalFee(), timeToMaturity);

        return
            Market.getfCashGivenCashAmount(
                market.totalfCash,
                netCashToAccount,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fee,
                0
            );
    }

    /// @notice Returns the cash amount that will be traded given an fCash amount, be sure to buffer these amounts
    /// slightly because the liquidity curve is sensitive to changes in block time
    function getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view override returns (int256, int256) {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Invalid block time");
        uint256 timeToMaturity = market.maturity - blockTime;

        // prettier-ignore
        (int256 assetCash, /* int fee */) =
            market.calculateTrade(cashGroup, fCashAmount, timeToMaturity, marketIndex);

        return (assetCash, cashGroup.assetRate.convertToUnderlying(assetCash));
    }

    /// @notice Returns the claimable incentives for all nToken balances
    /// @param account The address of the account which holds the tokens
    /// @param blockTime The block time when incentives will be minted
    /// @return Incentives an account is eligible to claim
    function nTokenGetClaimableIncentives(address account, uint256 blockTime)
        external
        view
        override
        returns (uint256)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        uint256 totalIncentivesClaimable;

        if (accountContext.isBitmapEnabled()) {
            balanceState.loadBalanceState(account, accountContext.bitmapCurrencyId, accountContext);
            if (balanceState.storedNTokenBalance > 0) {
                address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
                (
                    /* uint256 totalSupply */,
                    uint256 accumulatedNOTEPerNToken,
                    /* uint256 lastAccumulatedTime */
                ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

                uint256 incentivesToClaim = Incentives.calculateIncentivesToClaim(
                    balanceState,
                    tokenAddress,
                    accumulatedNOTEPerNToken,
                    balanceState.storedNTokenBalance.toUint()
                );
                totalIncentivesClaimable = totalIncentivesClaimable.add(incentivesToClaim);
            }
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            uint16 currencyId = uint16(bytes2(currencies) & Constants.UNMASK_FLAGS);
            balanceState.loadBalanceState(account, currencyId, accountContext);

            if (balanceState.storedNTokenBalance > 0) {
                address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
                (
                    /* uint256 totalSupply */,
                    uint256 accumulatedNOTEPerNToken,
                    /* uint256 lastAccumulatedTime */
                ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

                uint256 incentivesToClaim = Incentives.calculateIncentivesToClaim(
                    balanceState,
                    tokenAddress,
                    accumulatedNOTEPerNToken,
                    balanceState.storedNTokenBalance.toUint()
                );
                totalIncentivesClaimable = totalIncentivesClaimable.add(incentivesToClaim);
            }

            currencies = currencies << 16;
        }

        return totalIncentivesClaimable;
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external view returns (address) {
        return (address(MigrateIncentives));
    }
}