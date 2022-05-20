// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

interface IStakedNTokenAction {
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

    function stakedNTokenRedeemViaProxy(uint16 currencyId, uint256 shares, address receiver, address owner)
        external
        returns (uint256);

    function stakedNTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external
        returns (uint256);

    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId)
        external
        view
        returns (uint256);

    function stakedNTokenSignalUnstake(uint16 currencyId, address account, uint256 amount) external;
}