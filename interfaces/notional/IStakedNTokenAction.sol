// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;
pragma abicoder v2;

interface IStakedNTokenAction {
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
        external payable returns (uint256);

    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId)
        external
        view
        returns (uint256);

    function stakedNTokenSignalUnstakeViaProxy(uint16 currencyId, address account, uint256 amount) external;

    function stakeNTokenViaBatch(address account, uint16 currencyId, uint256 nTokensToStake)
        external returns (uint256);

    function unstakeNTokenViaBatch(address account, uint16 currencyId, uint256 snNTokens)
        external returns (uint256);

    function signalUnstakeNToken(uint16 currencyId, uint256 amount) external;
    function claimStakedNTokenIncentives(uint16[] calldata currencyId) external;
}