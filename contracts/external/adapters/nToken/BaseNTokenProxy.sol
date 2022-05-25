// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {Constants} from "../../../global/Constants.sol";
import {Token, TokenType} from "../../../global/Types.sol";
import {NotionalViews} from "../../../../interfaces/notional/NotionalViews.sol";
import {IERC4626} from "../../../../interfaces/IERC4626.sol";
import {WETH9} from "../../../../interfaces/WETH9.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/Initializable.sol";

/// @notice Each nToken will have its own proxy contract that forwards calls to the main Notional
/// proxy where all the storage is located. There are two types of nToken proxies: regular nToken
/// and staked nToken proxies which both implement ERC20 standards. Each nToken proxy is an upgradeable
/// beacon contract so that methods they proxy can be extended in the future.
/// @dev The first four nTokens deployed (ETH, DAI, USDC, WBTC) have non-upgradeable nToken proxy
/// contracts and are not easily upgraded. This may change in the future but requires a lot of testing
/// and may break backwards compatibility with integrations.
abstract contract BaseNTokenProxy is IERC20, IERC4626, Initializable {
    using SafeMath for uint256;

    /// @notice Inherits from Constants.INTERNAL_TOKEN_PRECISION
    uint8 public constant decimals = 8;

    /// @notice Address of the notional proxy, proxies only have access to a subset of the methods
    address public immutable Notional;

    /// @notice Use WETH for the underlying for nETH
    WETH9 public immutable WETH;

    // Below here are per currency storage slots, they are immutable once set on the proxy

    /// @notice Will be "[Staked] nToken {Underlying Token}.name()", therefore "USD Coin" will be
    /// "nToken USD Coin" for the regular nToken and "Staked nToken USD Coin" for the staked version.
    string public name;

    /// @notice Will be "[s]n{Underlying Token}.symbol()", therefore "USDC" will be "nUSDC"
    string public symbol;

    /// @notice Currency id that this nToken refers to
    uint16 public currencyId;

    /// @notice ERC20 underlying token referred to as the "asset" in IERC4626
    address public underlying;

    constructor(
        address notional_,
        address weth_
    ) initializer { 
        Notional = notional_;
        WETH = WETH9(weth_);
    }

    function _initialize(
        uint16 currencyId_,
        string memory underlyingName_,
        string memory underlyingSymbol_,
        bool isStaked
    ) internal initializer {
        currencyId = currencyId_;
        if (isStaked) {
            name = string(abi.encodePacked("Staked nToken ", underlyingName_));
            symbol = string(abi.encodePacked("sn", underlyingSymbol_));
        } else {
            name = string(abi.encodePacked("nToken ", underlyingName_));
            symbol = string(abi.encodePacked("n", underlyingSymbol_));
        }

        if (currencyId_ == Constants.ETH_CURRENCY_ID) {
            // If the underlying is ETH then we use WETH as the underlying
            underlying = address(WETH);
        } else {
            (
                Token memory assetToken,
                Token memory underlyingToken,
                /* ETHRate memory ethRate */,
                /* AssetRateParameters memory assetRate */
            ) = NotionalViews(address(Notional)).getCurrencyAndRates(currencyId);

            // The underlying token is set for the ERC4626 compatibility
            if (assetToken.tokenType == TokenType.NonMintable) {
                underlying = address(assetToken.tokenAddress);
            } else {
                underlying = address(underlyingToken.tokenAddress);
            }
        }
    }

    /// @notice Allow the Notional proxy to emit mint and burn events from the ERC20 contract so that
    /// token amounts can be tracked properly by tools like Etherscan
    function emitMint(address account, uint256 amount) external {
        require(msg.sender == address(Notional));
        emit Transfer(address(0), account, amount);
    }

    /// @notice Allow the Notional proxy to emit mint and burn events from the ERC20 contract so that
    /// token amounts can be tracked properly by tools like Etherscan
    function emitBurn(address account, uint256 amount) external {
        require(msg.sender == address(Notional));
        emit Transfer(account, address(0), amount);
    }

    /// @notice Returns the asset token reference by IERC4626, uses the underlying token as the asset
    /// for ERC4626 so that it is compatible with more use cases.
    function asset() external override view returns (address) { return underlying; }

    /// @notice Returns the total present value of the nTokens held in native underlying token precision
    function totalAssets() public override view returns (uint256 totalManagedAssets) {
        totalManagedAssets = _getUnderlyingPVExternal();
    }

    /// @notice Converts an underlying token to an nToken denomination
    function convertToShares(uint256 assets) public override view returns (uint256 shares) {
        // nTokenShares = totalSupply * assets / nTokenPV
        uint256 supply = totalSupply();
        if (supply == 0) return assets;

        shares = supply.mul(assets).div(totalAssets());
    }

    /// @notice Converts nToken denomination to underlying denomination
    function convertToAssets(uint256 shares) public override view returns (uint256 assets) {
        // assets = nTokenPV * shares / totalSupply
        uint256 supply = totalSupply();
        if (supply == 0) return shares;

        assets = totalAssets().mul(shares).div(supply);
    }

    /// @notice No supply constraints on nTokens or staked nTokens
    function maxDeposit(address /*receiver*/) external override pure returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    /// @notice No supply constraints on nTokens or staked nTokens
    function maxMint(address /*receiver*/) external override pure returns (uint256 maxShares) {
        return type(uint256).max;
    }

    /// @notice Deposits are based on the conversion rate assets to shares
    function previewDeposit(uint256 assets) external override view returns (uint256 shares) {
        return convertToShares(assets);
    }

    /// @notice Mints are based on the conversion rate from shares to assets
    function previewMint(uint256 shares) public override view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    /// @notice Return value is an over-estimation of the assets that the user will receive via redemptions,
    /// this method does not account for slippage and potential illiquid residuals. This method is not completely
    /// ERC4626 compliant in that sense.
    /// @dev Redemptions of nToken shares to underlying assets will experience slippage which is
    /// not easily calculated. In some situations, slippage may be so great that the shares are not able
    /// to be redeemed purely via the ERC4626 method and would require the account to call nTokenRedeem on
    /// AccountAction and take on illiquid fCash residuals.
    function previewRedeem(uint256 shares) external view override returns (uint256 assets) {
        return convertToAssets(shares);
    }

    /// @notice Return value is an under-estimation of the shares that the user will need to redeem to raise assets,
    /// this method does not account for slippage and potential illiquid residuals. This method is not completely
    /// ERC4626 compliant in that sense.
    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        return convertToShares(assets);
    }

    /// @notice Deposits assets into nToken for the receiver's account. Requires that the ERC4626 token has
    /// approval to transfer assets from the msg.sender directly to Notional.
    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        uint256 msgValue;
        (assets, msgValue) = _transferAssets(assets);
        shares = _mint(assets, msgValue, receiver);

        emit Transfer(address(0), receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Deposits assets into nToken for the receiver's account. Requires that the ERC4626 token has
    /// approval to transfer assets from the msg.sender directly to Notional.
    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        uint256 msgValue;
        assets = previewMint(shares);
        (assets, msgValue) = _transferAssets(assets);
        
        _mint(assets, msgValue, receiver);

        emit Transfer(address(0), receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _transferAssets(uint256 assets) private returns (uint256 assetsActual, uint256 msgValue) {
        if (currencyId == Constants.ETH_CURRENCY_ID) {
            // For WETH we transfer to this contract in order to unwrap it and then forward the native ETH.
            IERC20(address(WETH)).transferFrom(msg.sender, address(this), assets);
            WETH.withdraw(assets);

            assetsActual = assets;
            msgValue = assets;
        } else {
            // Transfer the underlying token directly to Notional to save a hop
            uint256 balanceBefore = IERC20(underlying).balanceOf(address(Notional));
            IERC20(underlying).transferFrom(msg.sender, address(Notional), assets);
            uint256 balanceAfter = IERC20(underlying).balanceOf(address(Notional));

            // Get the most accurate accounting of the assets transferred
            assetsActual = balanceAfter.sub(balanceBefore);
            msgValue = 0;
        }
    }

    /// @notice Redeems assets from the owner and sends them to the receiver. WARNING: the assets provided as a value here
    /// will not be what the method actually redeems due to estimation issues.
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        // NOTE: this will return an under-estimated amount for assets so the end amount of assets redeemed will
        // be less than specified.
        shares = previewWithdraw(assets);
        uint256 balance = balanceOf(owner);
        if (shares > balance) shares = balance;

        assets = _redeem(shares, receiver, owner);
        emit Transfer(owner, address(0), shares);

        // NOTE: the assets emitted here will be the correct value, but will not match what was provided.
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Redeems the specified amount of nTokens (shares) for some amount of assets.
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner);
        emit Transfer(owner, address(0), shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }


    // Virtual methods
    function initialize(uint16 currencyId_, string memory underlyingName_, string memory underlyingSymbol_) external virtual;
    function balanceOf(address account) public view override virtual returns (uint256);
    function totalSupply() public view override virtual returns (uint256 supply);
    function _getUnderlyingPVExternal() internal view virtual returns (uint256 pvUnderlyingExternal);
    function _mint(uint256 assets, uint256 msgValue, address receiver) internal virtual returns (uint256 tokensMinted);
    function _redeem(uint256 shares, address receiver, address owner) internal virtual returns (uint256 assets);
}
