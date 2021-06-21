// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../external/actions/GovernanceAction.sol";

contract GovernanceActionHarness is GovernanceAction {
    using TokenHandler for Token;
    using Market for MarketParameters;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;

    /** Governance Parameter Getters **/

    /// @notice Returns the current maximum currency id
    function getMaxCurrencyId() external view returns (uint16) {
        return maxCurrencyId;
    }

    /// @notice Returns a currency id, a zero means that it is not listed.
    function getCurrencyId(address tokenAddress) external view returns (uint16 currencyId) {
        currencyId = tokenAddressToCurrencyId[tokenAddress];
    }

    /// @notice Returns the asset token and underlying token related to a given currency id. If underlying
    /// token is not set then will return the zero address
    function getCurrency(uint16 currencyId)
        external
        view
        returns (Token memory assetToken, Token memory underlyingToken)
    {
        assetToken = TokenHandler.getToken(currencyId, false);
        underlyingToken = TokenHandler.getToken(currencyId, true);
    }

    /// @notice Returns the ETH and Asset rates for a currency as stored, useful for viewing how they are configured
    function getRateStorage(uint16 currencyId)
        external
        view
        returns (ETHRateStorage memory ethRate, AssetRateStorage memory assetRate)
    {
        ethRate = underlyingToETHRateMapping[currencyId];
        assetRate = assetToUnderlyingRateMapping[currencyId];
    }

    function getMaxMarketIndex(uint16 currencyId) external view returns (uint256) {
        return CashGroup.getMaxMarketIndex(currencyId);
    }

    /// @notice Returns market initialization parameters for a given currency
    function getInitializationParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory rateAnchors, int256[] memory proportions)
    {
        uint256 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        (rateAnchors, proportions) = nTokenHandler.getInitializationParameters(
            currencyId,
            maxMarketIndex
        );
    }

    /// @notice Returns nToken deposit parameters for a given currency
    function getDepositParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory depositShares, int256[] memory leverageThresholds)
    {
        uint256 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        (depositShares, leverageThresholds) = nTokenHandler.getDepositParameters(
            currencyId,
            maxMarketIndex
        );
    }

    /// @notice Returns nToken address for a given currency
    function nTokenAddress(uint16 currencyId) external view returns (address) {
        return nTokenHandler.nTokenAddress(currencyId);
    }

    function getNTokenAccount(address tokenAddress)
        external
        view
        returns (bytes6 nTokenParameters, uint256 incentiveAnnualEmissionRate)
    {
        // prettier-ignore
        (
            /* currencyId */,
            /* totalSupply */,
            incentiveAnnualEmissionRate,
            /* lastInitializedTime */,
            nTokenParameters
        ) = nTokenHandler.getNTokenContext(tokenAddress);
    }

    /// @notice Returns address of contract owner
    function getOwner() external view returns (address) {
        return owner;
    }
}
