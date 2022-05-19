// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {Token} from "../../../global/Types.sol";
import {NotionalViews} from "../../../../interfaces/notional/NotionalViews.sol";
import {IERC4626} from "../../../../interfaces/IERC4626.sol";
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

    // Below here are per currency storage slots, they are immutable once set on the proxy

    /// @notice Will be "[Staked] nToken {Underlying Token}.name()", therefore "USD Coin" will be
    /// nToken USD Coin
    string public name;

    /// @notice Will be "[s]n{Underlying Token}.symbol()", therefore "USDC" will be "nUSDC"
    string public symbol;

    /// @notice Currency id that this nToken refers to
    uint16 public currencyId;

    /// @notice ERC20 underlying token referred to as the "asset" in IERC4626
    address public underlying;

    constructor(address notional_) initializer { Notional = notional_; }

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

        (
            /* Token memory assetToken */,
            Token memory underlyingToken,
            /* ETHRate memory ethRate */,
            /* AssetRateParameters memory assetRate */
        ) = NotionalViews(address(Notional)).getCurrencyAndRates(currencyId);
        underlying = address(underlyingToken.tokenAddress);
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

    /// @notice Returns the asset token reference by IERC4626
    function asset() external override view returns (address) { return underlying; }

    /// @notice Returns the total present value of the nTokens held
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

        shares = totalAssets().mul(shares).div(supply);
    }

    /// @notice No supply constraints on nTokens or staked nTokens
    function maxDeposit(address /*receiver*/) external override pure returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    /// @notice No supply constraints on nTokens or staked nTokens
    function maxMint(address /*receiver*/) external override pure returns (uint256 maxShares) {
        return type(uint256).max;
    }

    /// @notice Deposits are based on conversion rates
    function previewDeposit(uint256 assets) external override view returns (uint256 shares) {
        return convertToShares(assets);
    }

    /// @notice Mints are based on conversion rates
    function previewMint(uint256 shares) public override view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        // Transfer the underlying token directly to Notional to save a hop
        IERC20(underlying).transferFrom(msg.sender, address(Notional), assets);
        shares = _mint(assets, receiver);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        assets = previewMint(shares);
        IERC20(underlying).transferFrom(msg.sender, address(Notional), assets);
        _mint(assets, receiver);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        uint256 balance = balanceOf(owner);
        if (shares > balance) shares = balance;

        _redeem(shares, receiver, owner);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        assets = _redeem(shares, receiver, owner);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // Virtual methods
    function initialize(uint16 currencyId_, string memory underlyingName_, string memory underlyingSymbol_) external virtual;
    function balanceOf(address account) public view override virtual returns (uint256);
    function totalSupply() public view override virtual returns (uint256 supply);
    function previewWithdraw(uint256 assets) public view override virtual returns (uint256 shares);
    function _getUnderlyingPVExternal() internal view virtual returns (uint256 pvUnderlyingExternal);
    function _mint(uint256 assets, address receiver) internal virtual returns (uint256 tokensMinted);
    function _redeem(uint256 shares, address receiver, address owner) internal virtual returns (uint256 assets);
}
