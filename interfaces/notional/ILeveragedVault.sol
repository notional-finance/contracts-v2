// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.0;

// Inherits ERC20? or ERC4626?
interface ILeveragedVault {

    // Tells a vault to mint vault shares given the amount of cash transferred
    function mintVaultShares(
        address account,
        uint256 newMaturity,
        uint256 oldMaturity,
        uint256 assetCashTransferred,
        int256 assetCashExchangeRate,
        bytes calldata data
    ) external returns (
        int256 accountUnderlyingInternalValue,
        uint256 vaultSharesMinted
    );

    // Redeems shares from the vault to asset cash.
    function redeemVaultShares(
        address account,
        uint256 vaultSharesToRedeem,
        uint256 maturity,
        bytes calldata data
    ) external returns (
        int256 accountUnderlyingInternalValue,
        uint256 assetCashExternal
    );


    function isInSettlement() external view returns (bool);
    function canSettleMaturity(uint256 maturity) external view returns (bool);
    function underlyingInternalValueOf(address account, uint256 maturity) external view returns (int256);
    function balanceOf(address account) external view returns (uint256);
}