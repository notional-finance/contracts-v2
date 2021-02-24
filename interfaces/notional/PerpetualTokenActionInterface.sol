// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

interface PerpetualTokenActionInterface {
    function perpetualTokenTotalSupply(address perpTokenAddress) external view returns (uint);

    function perpetualTokenTransferAllowance(
        uint16 currencyId,
        address owner,
        address spender
    ) external view returns (uint);

    function perpetualTokenBalanceOf(
        uint16 currencyId,
        address account
    ) external view returns (uint);

    function perpetualTokenTransferApprove(
        uint16 currencyId,
        address owner,
        address spender,
        uint amount
    ) external returns (bool);

    function perpetualTokenTransfer(
        uint16 currencyId,
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    function perpetualTokenTransferFrom(
        uint16 currencyId,
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    function perpetualTokenTransferApproveAll(
        address spender,
        uint amount
    ) external returns (bool);

    function perpetualTokenPresentValueAssetDenominated(
        uint16 currencyId
    ) external view returns (int);

    function perpetualTokenPresentValueUnderlyingDenominated(
        uint16 currencyId
    ) external view returns (int);
}
