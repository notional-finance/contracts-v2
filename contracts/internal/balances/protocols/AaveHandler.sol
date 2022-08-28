// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../../global/Types.sol";
import "../../../global/LibStorage.sol";
import "../../../math/SafeInt256.sol";
import "../TokenHandler.sol";
import "../../../../interfaces/aave/IAToken.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library AaveHandler {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    int256 internal constant RAY = 1e27;
    int256 internal constant halfRAY = RAY / 2;

    bytes4 internal constant scaledBalanceOfSelector = IAToken.scaledBalanceOf.selector;

    /**
     * @notice Mints an amount of aTokens corresponding to the the underlying.
     * @param underlyingToken address of the underlying token to pass to Aave
     * @param underlyingAmountExternal amount of underlying to deposit, in external precision
     */
    function mint(Token memory underlyingToken, uint256 underlyingAmountExternal) internal {
        // In AaveV3 this method is renamed to supply() but deposit() is still available for
        // backwards compatibility: https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/pool/Pool.sol#L755
        // We use deposit here so that mainnet-fork tests against Aave v2 will pass.
        LibStorage.getLendingPool().lendingPool.deposit(
            underlyingToken.tokenAddress,
            underlyingAmountExternal,
            address(this),
            0
        );
    }

    /**
     * @notice Redeems and sends an amount of aTokens to the specified account
     * @param underlyingToken address of the underlying token to pass to Aave
     * @param account account to receive the underlying
     * @param assetAmountExternal amount of aTokens in scaledBalanceOf terms
     */
    function redeem(
        Token memory underlyingToken,
        address account,
        uint256 assetAmountExternal
    ) internal returns (uint256 underlyingAmountExternal) {
        underlyingAmountExternal = convertFromScaledBalanceExternal(
            underlyingToken.tokenAddress,
            SafeInt256.toInt(assetAmountExternal)
        ).toUint();
        LibStorage.getLendingPool().lendingPool.withdraw(
            underlyingToken.tokenAddress,
            underlyingAmountExternal,
            account
        );
    }

    /**
     * @notice Takes an assetAmountExternal (in this case is the Aave balanceOf representing principal plus interest)
     * and returns another assetAmountExternal value which represents the Aave scaledBalanceOf (representing a proportional
     * claim on Aave principal plus interest onto the future). This conversion ensures that depositors into Notional will
     * receive future Aave interest.
     * @dev There is no loss of precision within this function since it does the exact same calculation as Aave.
     * @param currencyId is the currency id
     * @param assetAmountExternal an Aave token amount representing principal plus interest supplied by the user. This must
     * be positive in this function, this method is only called when depositing aTokens directly
     * @return scaledAssetAmountExternal the Aave scaledBalanceOf equivalent. The decimal precision of this value will
     * be in external precision.
     */
    function convertToScaledBalanceExternal(uint256 currencyId, int256 assetAmountExternal) internal view returns (int256) {
        if (assetAmountExternal == 0) return 0;
        require(assetAmountExternal > 0);

        Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
        // We know that this value must be positive
        int256 index = _getReserveNormalizedIncome(underlyingToken.tokenAddress);

        // Mimic the WadRay math performed by Aave (but do it in int256 instead)
        int256 halfIndex = index / 2;

        // Overflow will occur when: (a * RAY + halfIndex) > int256.max
        require(assetAmountExternal <= (type(int256).max - halfIndex) / RAY);

        // if index is zero then this will revert
        return (assetAmountExternal * RAY + halfIndex) / index;
    }

    /**
     * @notice Takes an assetAmountExternal (in this case is the internal scaledBalanceOf in external decimal precision)
     * and returns another assetAmountExternal value which represents the Aave balanceOf representing the principal plus interest
     * that will be transferred. This is required to maintain compatibility with Aave's ERC20 transfer functions.
     * @dev There is no loss of precision because this does exactly what Aave's calculation would do
     * @param underlyingToken token address of the underlying asset
     * @param netScaledBalanceExternal an amount representing the scaledBalanceOf in external decimal precision calculated from
     * Notional cash balances. This amount may be positive or negative depending on if assets are being deposited (positive) or
     * withdrawn (negative).
     * @return netBalanceExternal the Aave balanceOf equivalent as a signed integer
     */
    function convertFromScaledBalanceExternal(address underlyingToken, int256 netScaledBalanceExternal) internal view returns (int256 netBalanceExternal) {
        if (netScaledBalanceExternal == 0) return 0;

        // We know that this value must be positive
        int256 index = _getReserveNormalizedIncome(underlyingToken);
        // Use the absolute value here so that the halfRay rounding is applied correctly for negative values
        int256 abs = netScaledBalanceExternal.abs();

        // Mimic the WadRay math performed by Aave (but do it in int256 instead)

        // Overflow will occur when: (abs * index + halfRay) > int256.max
        // Here the first term is computed at compile time so it just does a division. If index is zero then
        // solidity will revert.
        require(abs <= (type(int256).max - halfRAY) / index);
        int256 absScaled = (abs * index + halfRAY) / RAY;

        return netScaledBalanceExternal > 0 ? absScaled : absScaled.neg();
    }

    /// @dev getReserveNormalizedIncome returns a uint256, so we know that the return value here is
    /// always positive even though we are converting to a signed int
    function _getReserveNormalizedIncome(address underlyingAsset) private view returns (int256) {
        return
            SafeInt256.toInt(
                LibStorage.getLendingPool().lendingPool.getReserveNormalizedIncome(underlyingAsset)
            );
    }
}