// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../../../interfaces/notional/ILeveragedVault.sol";

// TODO: does this fit our paradigm?
// import "../../../interfaces/IERC4626.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// TODO: consider upgrading this so we can compile in solidity 0.8
contract BaseStrategyVault {
//abstract contract BaseLeveragedVault is ILeveragedVault, ERC20, IERC4626 {
    function hello() external view returns (uint) { return 1; }
    
    // // Takes up two storage slots, allow the strategy tokens to have
    // // more storage since we don't know what scale they will be on
    // struct VaultMaturity {
    //     uint128 totalVaultShares;
    //     uint128 totalCashTokens;
    //     uint256 totalStrategyTokens;
    // }

    // /// @notice A mapping between vault shares and a maturity
    // mapping(uint256 => VaultMaturity) public vaultSharesPerMaturity;

    // /// @notice A mapping between an account and their balance
    // mapping(address => uint256) internal accountBalances;

    // uint16 internal immutable borrowCurrencyId;
    // address public immutable ASSET_TOKEN;
    // address public immutable UNDERLYING_TOKEN;
    // address public immutable NOTIONAL;

    // // TODO: confirm that controller does not rely on 8 decimal vault shares
    // constructor (
    //     string memory name_,
    //     string memory symbol_,
    //     address notional_,
    //     uint16 borrowCurrencyId_
    // ) initializer ERC20(name_, symbol_) {
    //     NOTIONAL = notional_;
    //     borrowCurrencyId = borrowCurrencyId_;
    //     // TODO: Init tokens here...
    // }

    // function mintVaultShares(
    //     address account,
    //     uint256 newMaturity,
    //     uint256 oldMaturity,
    //     uint256 assetCashTransferred,
    //     int256 assetCashExchangeRate,
    //     bytes calldata data
    // ) external returns (
    //     int256 accountUnderlyingInternalValue,
    //     uint256 vaultSharesMinted
    // ) {
    //     // Only Notional is authorized to mint vault shares
    //     require(msg.sender == NOTIONAL);

    //     uint256 previousMaturityCashTokens;
    //     uint256 strategyTokensToDeposit;
    //     if (oldMaturity != 0 && newMaturity != oldMaturity) {
    //         // If the account is moving maturities, then withdraw everything that remains from the old
    //         // maturity and transfer it to the new one.
    //         (
    //             previousMaturityCashTokens,
    //             strategyTokensToDeposit
    //         ) = _redeemVaultSharesInMaturity(account, oldMaturity, balanceOf(account));
    //     }

    //     VaultMaturity memory vaultMaturity = vaultSharesPerMaturity[newMaturity];

    //     // When minting, we need to maintain the ratio of tokens to asset cash (if there is any). This ensures
    //     // that redeeming vault shares for each account results in the same proportion of each token.
    //     uint256 assetCashToUse = previousMaturityCashTokens + assetCashTransferred;
    //     uint256 cashToDeposit;
    //     if (vaultMaturity.totalCashTokens > 0) {

    //         uint256 totalMaturityValueInAssetCash = 
    //             _convertToCashTokens(valueOfStrategyTokens(vaultMaturity.totalStrategyTokens)) +
    //             vaultMaturity.totalCashTokens;

    //         uint256 totalValueOfDeposits = 
    //             _convertToCashTokens(valueOfStrategyTokens(strategyTokensToDeposit)) +
    //             assetCashToUse;

    //         cashToDeposit = (totalValueOfDeposits * vaultMaturity.totalCashTokens) / totalMaturityValueInAssetCash;

    //         // It's possible that an account cannot roll into a new maturity when the new maturity is holding
    //         // cash tokens. It would need to redeem additional strategy tokens in order to have sufficient cash
    //         // to enter the new maturity. This is will only happen for accounts that are rolling maturities with
    //         // active strategy token positions (not entering maturities for the first time).
    //         require(cashToDeposit <= assetCashToUse, "Insufficient cash");
    //     }

    //     uint256 strategyTokensMinted = _mintStrategyTokens(account, newMaturity, assetCashToUse, data);
    //     vaultSharesMinted = _mintVaultSharesInMaturity(
    //         account,
    //         newMaturity,
    //         cashToDeposit,
    //         strategyTokensMinted,
    //         vaultMaturity
    //     );


    //     accountUnderlyingInternalValue = _convertToInternalPrecision(
    //         valueOfStrategyToken(accountStrategyTokens) + _convertToUnderlyingTokens(cashToDeposit)
    //     );
    // }

    // // Redeems shares from the vault to asset cash.
    // function redeemVaultShares(
    //     address account,
    //     uint256 vaultSharesToRedeem,
    //     uint256 maturity,
    //     bytes calldata data
    // ) external returns (
    //     int256 accountUnderlyingInternalValue,
    //     uint256 assetCashExternal
    // ) {
    //     require(msg.sender == NOTIONAL);
    //     (uint256 initialCashTokens, uint256 initialStrategyTokens) = getSharesOf(account, maturity);
    //     (
    //         uint256 cashTokensWithdrawn,
    //         uint256 strategyTokensWithdrawn,
    //     ) = _redeemVaultSharesInMaturity(account, maturity, vaultSharesToRedeem);

    //     assetCashExternal = cashTokensWithdrawn + _redeemStrategyTokens(account, maturity, strategyTokensWithdrawn, data);

    //     accountUnderlyingInternalValue = _convertToInternalPrecision(
    //         valueOfStrategyToken(initialStrategyTokens - strategyTokensWithdrawn) +
    //         _convertToUnderlyingTokens(initialCashTokens - cashTokensWithdrawn)
    //     );
    // }

    // function _mintVaultSharesInMaturity(
    //     address account,
    //     uint256 maturity,
    //     uint256 cashTokensDeposited,
    //     uint256 strategyTokensDeposited,
    //     VaultMaturity memory vaultMaturity
    // ) private returns (uint256 vaultSharesMinted) {
    //     if (vaultMaturity.totalVaultShares == 0) {
    //         vaultSharesMinted = strategyTokensDeposited;
    //     } else {
    //         vaultSharesMinted = (strategyTokensDeposited * vaultMaturity.totalVaultShares) / vaultMaturity.totalStrategyTokens;
    //     }

    //     // Update the vault maturity in storage
    //     vaultMaturity.totalCashTokens = vaultMaturity.totalCashTokens + cashTokensDeposited;
    //     vaultMaturity.totalStrategyTokens = vaultMaturity.totalStrategyTokens + strategyTokensDeposited;
    //     vaultMaturity.totalVaultShares = vaultMaturity.totalVaultShares + vaultSharesMinted;
    //     vaultSharesPerMaturity[maturity] = vaultMaturity;

    //     // Update global vault shares storage
    //     accountBalances[account] = accountBalances[account] + vaultSharesMinted;
    //     totalSupply = totalSupply + vaultSharesMinted;
    // }

    // function _redeemVaultSharesInMaturity(
    //     address account,
    //     uint256 maturity,
    //     uint256 vaultSharesToRedeem
    // ) private returns (
    //     uint256 cashTokensWithdrawn,
    //     uint256 strategyTokensWithdrawn
    // ) {
    //     // First update global supply storage
    //     accountBalances[account] = accountBalances[account] - vaultSharesToRedeem;
    //     totalSupply = totalSupply - vaultSharesToRedeem;

    //     // Calculate the claim on cash tokens and strategy tokens
    //     VaultShares memory vaultMaturity = vaultSharesPerMaturity[maturity];
    //     cashTokensWithdrawn = (vaultSharesToRedeem * vaultMaturity.totalCashTokens) / vaultMaturity.totalVaultShares;
    //     strategyTokensWithdrawn = (vaultSharesToRedeem * vaultMaturity.totalStrategyTokens) / vaultMaturity.totalVaultShares;

    //     // Remove tokens from the vaultMaturity and set the storage
    //     vaultMaturity.totalCashTokens = vaultShares.totalCashTokens - cashTokensWithdrawn;
    //     vaultMaturity.totalStrategyTokens = vaultShares.totalStrategyTokens - strategyTokensWithdrawn;
    //     vaultMaturity.totalVaultShares = vaultShares.totalVaultShares - vaultSharesToRedeem;
    //     vaultSharesPerMaturity[maturity] = vaultMaturity;
    // }


    // function underlyingInternalValueOf(address account, uint256 maturity) external view returns (int256);

    // // // TODO: put these on the main vault actions
    // // function assetValueOf(address account) external view returns (int256);
    // // function assetInternalValueOf(address account) external view returns (int256);
    // // function leverageRatioFor(address account) external view returns (uint256);
    // // function escrowedCashBalance(address account) external view returns (uint256);
    // function isInSettlement() external virtual view returns (bool);
    // function canSettleMaturity(uint256 maturity) external virtual view returns (bool);
    // function underlyingValueOf(address account) external virtual view returns (int256);

}