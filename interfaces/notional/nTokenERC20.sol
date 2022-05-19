// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;
pragma abicoder v2;

interface nTokenERC20 {
    event nTokenApproveAll(address indexed owner, address indexed spender, uint256 amount);

    function nTokenTotalSupply(address nTokenAddress) external view returns (uint256);

    function nTokenTransferAllowance(
        uint16 currencyId,
        address owner,
        address spender
    ) external view returns (uint256);

    function nTokenBalanceOf(uint16 currencyId, address account) external view returns (uint256);

    function nTokenTransferApprove(
        uint16 currencyId,
        address owner,
        address spender,
        uint256 amount
    ) external returns (bool);

    function nTokenTransfer(
        uint16 currencyId,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function nTokenTransferFrom(
        uint16 currencyId,
        address spender,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function nTokenTransferApproveAll(address spender, uint256 amount) external returns (bool);

    function nTokenClaimIncentives() external returns (uint256);

    function nTokenPresentValueAssetDenominated(uint16 currencyId) external view returns (int256);

    function nTokenPresentValueUnderlyingDenominated(uint16 currencyId)
        external
        view
        returns (int256);

    function nTokenPresentValueUnderlyingExternal(uint16 currencyId)
        external
        view
        returns (uint256);

    function nTokenRedeemViaProxy(uint16 currencyId, uint256 shares, address receiver, address owner)
        external
        returns (uint256);

    function nTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external
        returns (uint256);

    function emitMint(address account, uint256 amount) external;
    function emitBurn(address account, uint256 amount) external;
}

interface StakedNTokenERC20 {
    // TODO: allowances on the staked nToken are set on each contract individually
    function stakedNTokenTotalSupply(uint16 currencyId) external view returns (uint256);

    function stakedNTokenBalanceOf(uint16 currencyId, address account) external view returns (uint256);

    function stakedNTokenRedeemAllowed(uint16 currencyId, address account) external view returns (uint256);

    function stakedNTokenTransfer(
        uint16 currencyId,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function stakedNTokenTransferFrom(
        uint16 currencyId,
        address spender,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function stakedNTokenRedeemViaProxy(uint16 currencyId, uint256 shares, address receiver, address owner)
        external
        view
        returns (uint256);

    function stakedNTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external
        view
        returns (uint256);

    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId)
        external
        view
        returns (uint256);

    function stakedNTokenSignalUnstake(uint16 currencyId, address account, uint256 amount)
        external
        view
        returns (uint256);
}

interface nTokenProxy is nTokenERC20, StakedNTokenERC20 { }