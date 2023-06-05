// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import {MockERC20} from "./MockERC20.sol";
import {IERC4626} from "../../interfaces/IERC4626.sol";
import {IERC20} from "../../interfaces/IERC20.sol";

contract MockERC4626 is MockERC20, IERC4626 {
    address public override immutable asset;

    uint256 public scaleFactor;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint fee,
        address asset_,
        uint256 scaleFactor_
    ) MockERC20(name_, symbol_, decimals_, fee) {
        asset = asset_;
        scaleFactor = scaleFactor_;
    }

    function setScaleFactor(uint256 newScaleFactor) external {
        scaleFactor = newScaleFactor;
    }

    function totalAssets()
        external
        view
        override
        returns (uint256 totalManagedAssets)
    {
        return 1;
    }

    function convertToShares(
        uint256 assets
    ) external view override returns (uint256 shares) {
        return assets;
    }

    function convertToAssets(
        uint256 shares
    ) external view override returns (uint256 assets) {
        return shares * scaleFactor / 100;
    }

    function maxDeposit(
        address receiver
    ) external view override returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    function previewDeposit(
        uint256 assets
    ) external view override returns (uint256 shares) {
        return assets;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) external override returns (uint256 shares) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _transfer(address(this), receiver, assets);
        return assets;
    }

    function maxMint(
        address receiver
    ) external view override returns (uint256 maxShares) {
        return type(uint256).max;
    }

    function previewMint(
        uint256 shares
    ) external view override returns (uint256 assets) {
        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) external override returns (uint256 assets) {
        return shares;
    }

    function maxWithdraw(
        address owner
    ) external view override returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    function previewWithdraw(
        uint256 assets
    ) external view override returns (uint256 shares) {
        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external override returns (uint256 shares) {
        transferFrom(receiver, address(this), assets);
        IERC20(asset).transfer(receiver, assets);
        return assets;
    }

    function maxRedeem(
        address owner
    ) external view override returns (uint256 maxShares) {
        return type(uint256).max;
    }

    function previewRedeem(
        uint256 shares
    ) external view override returns (uint256 assets) {
        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external override returns (uint256 assets) {
        return shares;
    }
}
