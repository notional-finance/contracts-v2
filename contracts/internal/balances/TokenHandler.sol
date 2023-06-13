// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    Token,
    TokenType,
    TokenStorage,
    PrimeRate
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Constants} from "../../global/Constants.sol";
import {Deployments} from "../../global/Deployments.sol";

import {Emitter} from "../Emitter.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";

import {CompoundHandler} from "./protocols/CompoundHandler.sol";
import {GenericToken} from "./protocols/GenericToken.sol";

import {IERC20} from "../../../interfaces/IERC20.sol";
import {IPrimeCashHoldingsOracle, RedeemData} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

/// @notice Handles all external token transfers and events
library TokenHandler {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using PrimeRateLib for PrimeRate;

    function getDeprecatedAssetToken(uint256 currencyId) internal view returns (Token memory) {
        return _getToken(currencyId, false);
    }

    function getUnderlyingToken(uint256 currencyId) internal view returns (Token memory) {
        return _getToken(currencyId, true);
    }

    /// @notice Gets token data for a particular currency id, if underlying is set to true then returns
    /// the underlying token. (These may not always exist)
    function _getToken(uint256 currencyId, bool underlying) private view returns (Token memory) {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        TokenStorage storage tokenStorage = store[currencyId][underlying];

        return
            Token({
                tokenAddress: tokenStorage.tokenAddress,
                hasTransferFee: tokenStorage.hasTransferFee,
                // No overflow, restricted on storage
                decimals: int256(10**tokenStorage.decimalPlaces),
                tokenType: tokenStorage.tokenType,
                deprecated_maxCollateralBalance: 0
            });
    }

    /// @notice Sets a token for a currency id. After the prime cash migration, only
    /// underlying tokens may be set by this method.
    function setToken(uint256 currencyId, TokenStorage memory tokenStorage) internal {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();

        if (tokenStorage.tokenType == TokenType.Ether && currencyId == Constants.ETH_CURRENCY_ID) {
            // Hardcoded parameters for ETH just to make sure we don't get it wrong.
            TokenStorage storage ts = store[currencyId][true];
            ts.tokenAddress = address(0);
            ts.hasTransferFee = false;
            ts.tokenType = TokenType.Ether;
            ts.decimalPlaces = Constants.ETH_DECIMAL_PLACES;

            return;
        }

        // Check token address
        require(tokenStorage.tokenAddress != address(0), "TH: address is zero");
        // Once a token is set we cannot override it. In the case that we do need to do change a token address
        // then we should explicitly upgrade this method to allow for a token to be changed.
        Token memory token = _getToken(currencyId, true);
        require(
            token.tokenAddress == tokenStorage.tokenAddress || token.tokenAddress == address(0),
            "TH: token cannot be reset"
        );

        require(0 < tokenStorage.decimalPlaces 
            && tokenStorage.decimalPlaces <= Constants.MAX_DECIMAL_PLACES, "TH: invalid decimals");

        // Validate token type
        require(tokenStorage.tokenType != TokenType.Ether); // dev: ether can only be set once
        // Only underlying tokens allowed after migration
        require(tokenStorage.tokenType == TokenType.UnderlyingToken); // dev: only underlying token

        // Underlying is always true.
        store[currencyId][true] = tokenStorage;
    }

    /**
     * @notice Transfers a deprecated asset token into Notional and redeems it for underlying,
     * updates prime cash supply and returns the total prime cash to add to the account.
     * @param assetToken asset token to redeem
     * @param currencyId the currency id of the token
     * @param assetAmountExternal the amount to transfer in asset token denomination and external precision
     * @param primeRate the prime rate for the given currency
     * @param account the address of the account to transfer from
     * @return primeCashDeposited the amount of prime cash to mint back to the account
     */
    function depositDeprecatedAssetToken(
        Token memory assetToken,
        uint16 currencyId,
        uint256 assetAmountExternal,
        address account,
        PrimeRate memory primeRate
    ) internal returns (int256 primeCashDeposited) {
        // Transfer the asset token into the contract
        assetAmountExternal = GenericToken.safeTransferIn(
            assetToken.tokenAddress, account, assetAmountExternal
        );

        Token memory underlyingToken = getUnderlyingToken(currencyId);
        int256 underlyingExternalAmount;
        // Only cTokens will be listed at the time of the migration. Redeem
        // those cTokens to underlying (to be held by the Notional contract)
        // and then run the post transfer update
        if (assetToken.tokenType == TokenType.cETH) {
            underlyingExternalAmount = CompoundHandler.redeemCETH(
                assetToken, assetAmountExternal
            ).toInt();
        } else if (assetToken.tokenType == TokenType.cToken) {
            underlyingExternalAmount = CompoundHandler.redeem(
                assetToken, underlyingToken, assetAmountExternal
            ).toInt();
        } else {
            // No other asset token variants can be called here.
            revert();
        }
        
        primeCashDeposited = _postTransferPrimeCashUpdate(
            account, currencyId, underlyingExternalAmount, underlyingToken, primeRate
        );
    }

    /// @notice Deposits an exact amount of underlying tokens to mint the specified amount of prime cash.
    /// @param account account to transfer tokens from
    /// @param currencyId the associated currency id
    /// @param primeCashToMint the amount of prime cash to mint
    /// @param primeRate the current accrued prime rate
    /// @param returnNativeTokenWrapped if true, return excess msg.value ETH payments as WETH
    /// @return actualTransferExternal the actual amount of tokens transferred in external precision
    function depositExactToMintPrimeCash(
        address account,
        uint16 currencyId,
        int256 primeCashToMint,
        PrimeRate memory primeRate,
        bool returnNativeTokenWrapped
    ) internal returns (int256 actualTransferExternal) {
        if (primeCashToMint == 0) return 0;
        require(primeCashToMint > 0);
        Token memory underlying = getUnderlyingToken(currencyId);
        int256 netTransferExternal = convertToUnderlyingExternalWithAdjustment(
            underlying, 
            primeRate.convertToUnderlying(primeCashToMint) 
        );

        int256 netPrimeSupplyChange;
        (actualTransferExternal, netPrimeSupplyChange) = depositUnderlyingExternal(
            account, currencyId, netTransferExternal, primeRate, returnNativeTokenWrapped
        );

        // Ensures that the prime cash minted is positive and always greater than
        // the amount of prime cash that will be credited to the depositor. Any dust
        // amounts here will accrue to the protocol. primeCashToMint is asserted to be
        // positive so if netPrimeSupplyChange is negative (which it should never be),
        // then this will revert as well.
        int256 diff = netPrimeSupplyChange - primeCashToMint;
        require(0 <= diff); // dev: diff above zero
        require(diff <= 500); // dev: diff above error
    }

    /// @notice Deposits an amount of underlying tokens to mint prime cash
    /// @param account account to transfer tokens from
    /// @param currencyId the associated currency id
    /// @param _underlyingExternalDeposit the amount of underlying tokens to deposit
    /// @param primeRate the current accrued prime rate
    /// @param returnNativeTokenWrapped if true, return excess msg.value ETH payments as WETH
    /// @return actualTransferExternal the actual amount of tokens transferred in external precision
    /// @return netPrimeSupplyChange the amount of prime supply created
    function depositUnderlyingExternal(
        address account,
        uint16 currencyId,
        int256 _underlyingExternalDeposit,
        PrimeRate memory primeRate,
        bool returnNativeTokenWrapped
    ) internal returns (int256 actualTransferExternal, int256 netPrimeSupplyChange) {
        uint256 underlyingExternalDeposit = _underlyingExternalDeposit.toUint();
        if (underlyingExternalDeposit == 0) return (0, 0);

        Token memory underlying = getUnderlyingToken(currencyId);
        if (underlying.tokenType == TokenType.Ether) {
            // Underflow checked above
            if (underlyingExternalDeposit < msg.value) {
                // Transfer any excess ETH back to the account
                GenericToken.transferNativeTokenOut(
                    account, msg.value - underlyingExternalDeposit, returnNativeTokenWrapped
                );
            } else {
                require(underlyingExternalDeposit == msg.value, "ETH Balance");
            }

            actualTransferExternal = _underlyingExternalDeposit;
        } else {
            // In the case of deposits, we use a balance before and after check
            // to ensure that we record the proper balance change.
            actualTransferExternal = GenericToken.safeTransferIn(
                underlying.tokenAddress, account, underlyingExternalDeposit
            ).toInt();
        }

        netPrimeSupplyChange = _postTransferPrimeCashUpdate(
            account, currencyId, actualTransferExternal, underlying, primeRate
        );
    }

    /// @notice Withdraws an amount of prime cash and returns it to the account as underlying tokens
    /// @param account account to transfer tokens to
    /// @param currencyId the associated currency id
    /// @param primeCashToWithdraw the amount of prime cash to burn
    /// @param primeRate the current accrued prime rate
    /// @param withdrawWrappedNativeToken if true, return ETH as WETH
    /// @return netTransferExternal the amount of underlying tokens withdrawn in native precision, this is
    /// negative to signify that tokens have left the protocol
    function withdrawPrimeCash(
        address account,
        uint16 currencyId,
        int256 primeCashToWithdraw,
        PrimeRate memory primeRate,
        bool withdrawWrappedNativeToken
    ) internal returns (int256 netTransferExternal) {
        if (primeCashToWithdraw == 0) return 0;
        require(primeCashToWithdraw < 0);

        Token memory underlying = getUnderlyingToken(currencyId);
        netTransferExternal = convertToExternal(
            underlying, 
            primeRate.convertToUnderlying(primeCashToWithdraw) 
        );

        // Overflow not possible due to int256
        uint256 withdrawAmount = uint256(netTransferExternal.neg());
        _redeemMoneyMarketIfRequired(currencyId, underlying, withdrawAmount);

        if (underlying.tokenType == TokenType.Ether) {
            GenericToken.transferNativeTokenOut(account, withdrawAmount, withdrawWrappedNativeToken);
        } else {
            GenericToken.safeTransferOut(underlying.tokenAddress, account, withdrawAmount);
        }

        _postTransferPrimeCashUpdate(account, currencyId, netTransferExternal, underlying, primeRate);
    }

    /// @notice Prime cash holdings may be in underlying tokens or they may be held in other money market
    /// protocols like Compound, Aave or Euler. If there is insufficient underlying tokens to withdraw on
    /// the contract, this method will redeem money market tokens in order to gain sufficient underlying
    /// to withdraw from the contract.
    /// @param currencyId associated currency id
    /// @param underlying underlying token information
    /// @param withdrawAmountExternal amount of underlying to withdraw in external token precision
    function _redeemMoneyMarketIfRequired(
        uint16 currencyId,
        Token memory underlying,
        uint256 withdrawAmountExternal
    ) private {
        // If there is sufficient balance of the underlying to withdraw from the contract
        // immediately, just return.
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        uint256 currentBalance = store[underlying.tokenAddress];
        if (withdrawAmountExternal <= currentBalance) return;

        IPrimeCashHoldingsOracle oracle = PrimeCashExchangeRate.getPrimeCashHoldingsOracle(currencyId);
        // Redemption data returns an array of contract calls to make from the Notional proxy (which
        // is holding all of the money market tokens).
        (RedeemData[] memory data) = oracle.getRedemptionCalldata(withdrawAmountExternal - currentBalance);

        // This is the total expected underlying that we should redeem after all redemption calls
        // are executed.
        uint256 totalUnderlyingRedeemed = executeMoneyMarketRedemptions(underlying, data);

        // Ensure that we have sufficient funds before we exit
        require(withdrawAmountExternal <= currentBalance.add(totalUnderlyingRedeemed)); // dev: insufficient redeem
    }

    /// @notice Every time tokens are transferred into or out of the protocol, the prime supply
    /// and total underlying held must be updated.
    function _postTransferPrimeCashUpdate(
        address account,
        uint16 currencyId,
        int256 netTransferUnderlyingExternal,
        Token memory underlyingToken,
        PrimeRate memory primeRate
    ) private returns (int256 netPrimeSupplyChange) {
        int256 netUnderlyingChange = convertToInternal(underlyingToken, netTransferUnderlyingExternal);

        netPrimeSupplyChange = primeRate.convertFromUnderlying(netUnderlyingChange);

        Emitter.emitMintOrBurnPrimeCash(account, currencyId, netPrimeSupplyChange);
        PrimeCashExchangeRate.updateTotalPrimeSupply(currencyId, netPrimeSupplyChange, netUnderlyingChange);

        _updateNetStoredTokenBalance(underlyingToken.tokenAddress, netTransferUnderlyingExternal);
    }

    function convertToInternal(Token memory token, int256 amount) internal pure returns (int256) {
        // If token decimals > INTERNAL_TOKEN_PRECISION:
        //  on deposit: resulting dust will accumulate to protocol
        //  on withdraw: protocol may lose dust amount. However, withdraws are only calculated based
        //    on a conversion from internal token precision to external token precision so therefore dust
        //    amounts cannot be specified for withdraws.
        // If token decimals < INTERNAL_TOKEN_PRECISION then this will add zeros to the
        // end of amount and will not result in dust.
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        return amount.mul(Constants.INTERNAL_TOKEN_PRECISION).div(token.decimals);
    }

    function convertToExternal(Token memory token, int256 amount) internal pure returns (int256) {
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        // If token decimals > INTERNAL_TOKEN_PRECISION then this will increase amount
        // by adding a number of zeros to the end and will not result in dust.
        // If token decimals < INTERNAL_TOKEN_PRECISION:
        //  on deposit: Deposits are specified in external token precision and there is no loss of precision when
        //      tokens are converted from external to internal precision
        //  on withdraw: this calculation will round down such that the protocol retains the residual cash balance
        return amount.mul(token.decimals).div(Constants.INTERNAL_TOKEN_PRECISION);
    }

    /// @notice Converts a token to an underlying external amount with adjustments for rounding errors when depositing
    function convertToUnderlyingExternalWithAdjustment(
        Token memory token,
        int256 underlyingInternalAmount
    ) internal pure returns (int256 underlyingExternalAmount) {
        if (token.decimals < Constants.INTERNAL_TOKEN_PRECISION) {
            // If external < 8, we could truncate down and cause an off by one error, for example we need
            // 1.00000011 cash and we deposit only 1.000000, missing 11 units. Therefore, we add a unit at the
            // lower precision (external) to get around off by one errors
            underlyingExternalAmount = convertToExternal(token, underlyingInternalAmount).add(1);
        } else {
            // If external > 8, we may not mint enough asset tokens because in the case of 1e18 precision 
            // an off by 1 error at 1e8 precision is 1e10 units of the underlying token. In this case we
            // add 1 at the internal precision which has the effect of rounding up by 1e10
            underlyingExternalAmount = convertToExternal(token, underlyingInternalAmount.add(1));
        }
    }

    /// @notice Convenience method for getting the balance using a token object
    function balanceOf(Token memory token, address account) internal view returns (uint256) {
        if (token.tokenType == TokenType.Ether) {
            return account.balance;
        } else {
            return IERC20(token.tokenAddress).balanceOf(account);
        }
    }

    function transferIncentive(address account, uint256 tokensToTransfer) internal {
        GenericToken.safeTransferOut(Deployments.NOTE_TOKEN_ADDRESS, account, tokensToTransfer);
    }

    /// @notice It is critical that this method measures and records the balanceOf changes before and after
    /// every token change. If not, then external donations can affect the valuation of pCash and pDebt
    /// tokens which may be exploitable.
    /// @param redeemData parameters from the prime cash holding oracle
    function executeMoneyMarketRedemptions(
        Token memory underlyingToken,
        RedeemData[] memory redeemData
    ) internal returns (uint256 totalUnderlyingRedeemed) {
        for (uint256 i; i < redeemData.length; i++) {
            RedeemData memory data = redeemData[i];
            // Measure the token balance change if the `assetToken` value is set in the
            // current redemption data struct. 
            uint256 oldAssetBalance = IERC20(data.assetToken).balanceOf(address(this));

            // Measure the underlying balance change before and after the call.
            uint256 oldUnderlyingBalance = balanceOf(underlyingToken, address(this));
            
            // Some asset tokens may require multiple calls to redeem if there is an unstake
            // or redemption from WETH involved. We only measure the asset token balance change
            // on the final redemption call, as dictated by the prime cash holdings oracle.
            for (uint256 j; j < data.targets.length; j++) {
                // This will revert if the individual call reverts.
                GenericToken.executeLowLevelCall(data.targets[j], 0, data.callData[j]);
            }

            // Ensure that we get sufficient underlying on every redemption
            uint256 newUnderlyingBalance = balanceOf(underlyingToken, address(this));
            uint256 underlyingBalanceChange = newUnderlyingBalance.sub(oldUnderlyingBalance);
            // If the call is not the final redemption, then expectedUnderlying should
            // be set to zero.
            require(data.expectedUnderlying <= underlyingBalanceChange);
        
            // Measure and update the asset token
            uint256 newAssetBalance = IERC20(data.assetToken).balanceOf(address(this));
            require(newAssetBalance <= oldAssetBalance);
            updateStoredTokenBalance(data.assetToken, oldAssetBalance, newAssetBalance);

            // Update the total value with the net change
            totalUnderlyingRedeemed = totalUnderlyingRedeemed.add(underlyingBalanceChange);

            // totalUnderlyingRedeemed is always positive or zero.
            updateStoredTokenBalance(underlyingToken.tokenAddress, oldUnderlyingBalance, newUnderlyingBalance);
        }
    }

    function updateStoredTokenBalance(address token, uint256 oldBalance, uint256 newBalance) internal {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        uint256 storedBalance = store[token];
        // The stored balance must always be less than or equal to the previous balance of. oldBalance
        // will be larger in the case when there is a donation or dust value present. If stored balance somehow
        // goes above the oldBalance then there is a critical issue in the protocol.
        require(storedBalance <= oldBalance);
        int256 netBalanceChange = newBalance.toInt().sub(oldBalance.toInt());
        store[token] = int256(storedBalance).add(netBalanceChange).toUint();
    }

    function _updateNetStoredTokenBalance(address token, int256 netBalanceChange) private {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        uint256 storedBalance = store[token];
        store[token] = int256(storedBalance).add(netBalanceChange).toUint();
    }
}
