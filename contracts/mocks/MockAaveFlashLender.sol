// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);

    //   function ADDRESSES_PROVIDER() external view returns (address);

    //   function LENDING_POOL() external view returns (address);
}

contract MockAaveFlashLender {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external {
        uint256[] memory premiums = new uint256[](assets.length);

        for (uint256 i; i < assets.length; i++) {
            // 9 basis point fee
            premiums[i] = (amounts[i] * 9) / 10000;
            IERC20(assets[i]).transfer(receiverAddress, amounts[i]);
        }

        bool success = IFlashLoanReceiver(receiverAddress).executeOperation(assets, amounts, premiums, msg.sender, params);
        require(success);

        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).transferFrom(
                receiverAddress,
                address(this),
                amounts[i] + premiums[i]
            );
        }
    }
}
