// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "interfaces/notional/NotionalProxy.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "../../proxy/utils/UUPSUpgradeable.sol";

interface WETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

abstract contract NotionalV2BaseLiquidator is Initializable, UUPSUpgradeable {
    enum LiquidationAction {
        LocalCurrency_NoTransferFee,
        CollateralCurrency_NoTransferFee,
        LocalfCash_NoTransferFee,
        CrossCurrencyfCash_NoTransferFee,
        LocalCurrency_WithTransferFee,
        CollateralCurrency_WithTransferFee,
        LocalfCash_WithTransferFee,
        CrossCurrencyfCash_WithTransferFee
    }

    NotionalProxy public NotionalV2;
    mapping(address => address) underlyingToCToken;
    address public WETH;
    address public cETH;
    address public OWNER;

    modifier onlyOwner() {
        require(OWNER == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /// @dev Only the owner may upgrade the contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function __NotionalV2BaseLiquidator_init(
        NotionalProxy notionalV2_,
        address weth_,
        address cETH_,
        address owner_
    ) internal initializer {
        NotionalV2 = notionalV2_;
        WETH = weth_;
        cETH = cETH_;
        OWNER = owner_;
    }

    function executeDexTrade(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory params
    ) internal virtual;
}
