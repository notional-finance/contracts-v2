// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin-4.6/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin-4.6/contracts/security/ReentrancyGuard.sol";
import {ERC20Upgradeable} from "@openzeppelin-4.6/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-4.6/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CTokenInterface} from "../../../interfaces/compound/CTokenInterface.sol";
import {CEtherInterface} from "../../../interfaces/compound/CEtherInterface.sol";
import {CErc20Interface} from "../../../interfaces/compound/CErc20Interface.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {nwTokenInterface} from "../../../interfaces/notional/nwTokenInterface.sol";

contract nwToken is ERC20Upgradeable, ReentrancyGuard, UUPSUpgradeable, nwTokenInterface {
    using SafeERC20 for ERC20;

    address public constant ETH_ADDRESS = address(0);
    uint256 internal constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 internal constant NO_ERROR = 0;

    address public immutable NOTIONAL;
    address private immutable COMPOUND_TOKEN;
    address private immutable UNDERLYING_TOKEN;
    uint8 private immutable CTOKEN_DECIMALS;

    uint256 private finalExchangeRate;

    modifier onlyNotional() {
        require(msg.sender == NOTIONAL);
        _;
    }

    modifier onlyNotionalOwner() {
        require(msg.sender == NotionalProxy(NOTIONAL).owner());
        _;
    }

    constructor(address notional_, address cToken_, bool isETH_) initializer {
        CTOKEN_DECIMALS = ERC20(cToken_).decimals();
        COMPOUND_TOKEN = cToken_;
        NOTIONAL = notional_;
        UNDERLYING_TOKEN = isETH_ ? ETH_ADDRESS : CTokenInterface(cToken_).underlying();
    }

    function initialize(uint256 finalExchangeRate_) external initializer onlyNotional {
        string memory underlyingName = UNDERLYING_TOKEN == ETH_ADDRESS ? 
            'Ether' :
            ERC20(UNDERLYING_TOKEN).name();

        string memory underlyingSymbol = UNDERLYING_TOKEN == ETH_ADDRESS ? 
            'ETH' :
            ERC20(UNDERLYING_TOKEN).symbol();

        __ERC20_init(
            string(abi.encodePacked("Notional Wrapped ", underlyingName)), 
            string(abi.encodePacked("nw", underlyingSymbol))
        );
        finalExchangeRate = finalExchangeRate_;
    }

    // ERC20 functions
    function decimals() public view override returns (uint8) {
        return CTOKEN_DECIMALS;
    }

    // CEtherInterface functions
    function mint() external payable nonReentrant override {
        require(UNDERLYING_TOKEN == ETH_ADDRESS);
        require(finalExchangeRate != 0);

        if (msg.value == 0) revert("No ETH");

        uint256 assetTokenAmount = _convertToAsset(msg.value);
        require(assetTokenAmount > 0, "No Shares");

        // Handles event emission, balance update and total supply update
        super._mint(msg.sender, assetTokenAmount);
        _checkSupplyInvariant();
    }

    // CErc20Interface functions 
    function mint(uint mintAmount) external nonReentrant override returns (uint) {
        require(UNDERLYING_TOKEN != ETH_ADDRESS);
        require(finalExchangeRate != 0);

        if (mintAmount == 0) return NO_ERROR;

        ERC20(UNDERLYING_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            mintAmount
        );
        uint256 assetTokenAmount = _convertToAsset(mintAmount);
        require(assetTokenAmount > 0, "No Shares");

        // Handles event emission, balance update and total supply update
        super._mint(msg.sender, assetTokenAmount);

        _checkSupplyInvariant();
        return NO_ERROR;
    }

    function redeem(uint redeemTokens) external nonReentrant override returns (uint) {
        if (redeemTokens == 0) return NO_ERROR;
        require(finalExchangeRate != 0);

        // Handles event emission, balance update and total supply update
        super._burn(msg.sender, redeemTokens);

        _transferUnderlyingToSender(_convertToUnderlying(redeemTokens));
        
        _checkSupplyInvariant();
        return NO_ERROR;
    }

    function redeemUnderlying(uint redeemAmount) external nonReentrant override returns (uint) {
        if (redeemAmount == 0) return NO_ERROR;
        require(finalExchangeRate != 0);

        // Handles event emission, balance update and total supply update.
        super._burn(msg.sender, _convertToAssetRoundUp(redeemAmount));

        _transferUnderlyingToSender(redeemAmount);

        _checkSupplyInvariant();
        return NO_ERROR;
    }

    function _checkSupplyInvariant() private view {
        uint256 totalSupplyInUnderlying = _convertToUnderlying(totalSupply());
        uint256 balanceOfUnderlying = UNDERLYING_TOKEN == ETH_ADDRESS ?
            address(this).balance :
            ERC20(UNDERLYING_TOKEN).balanceOf(address(this));

        require(totalSupplyInUnderlying <= balanceOfUnderlying, "Invariant Failed");
    }

    function _transferUnderlyingToSender(uint256 amount) private {
        if (UNDERLYING_TOKEN == ETH_ADDRESS) {
            payable(msg.sender).transfer(amount);
        } else {
            ERC20(UNDERLYING_TOKEN).safeTransfer(msg.sender, amount);
        }
    }

    // AssetRateAdapter functions
    function token() external view returns (address) {
        return address(this);
    }

    function description() external view returns (string memory) {
        return super.symbol();
    }

    function version() external view returns (uint256) {
        return 1;
    }

    function underlying() external view returns (address) {
        return UNDERLYING_TOKEN;
    }

    function getExchangeRateStateful() external returns (int256) {
        return _toInt(finalExchangeRate);
    }

    function getExchangeRateView() external view returns (int256) {
        return _toInt(finalExchangeRate);
    }

    function getAnnualizedSupplyRate() external view returns (uint256) {
        return 0;
    }

    function _toInt(uint256 x) private pure returns (int256) {
        require (x <= uint256(type(int256).max)); // dev: toInt overflow
        return int256(x);
    }

    function _convertToAsset(uint256 underlyingAmount) private view returns (uint256) {
        return underlyingAmount * EXCHANGE_RATE_PRECISION / finalExchangeRate;
    }

    function _convertToAssetRoundUp(uint256 underlyingAmount) private view returns (uint256) {
        return underlyingAmount == 0 ? 0 :
            ((underlyingAmount * EXCHANGE_RATE_PRECISION - 1) / finalExchangeRate) + 1;
    }

    function _convertToUnderlying(uint256 assetAmount) private view returns (uint256) {
        return assetAmount * finalExchangeRate / EXCHANGE_RATE_PRECISION;
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal override onlyNotionalOwner {}
}
