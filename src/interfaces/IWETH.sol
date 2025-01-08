// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.25;

import "./IERC20.sol";

/// @title WETH interface
/// @notice Interface for the WETH token.
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
