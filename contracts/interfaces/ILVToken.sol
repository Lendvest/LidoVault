// SPDX-License-Identifier: MIT
// Copyright (c) 2025 KLV1, Inc.

pragma solidity ^0.8.20;

interface ILVToken {
    // Standard ERC20 functions
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    // Additional functions for collateral token management
    function mint(address account, uint256 amount) external returns (bool);
    function burn(address from, uint256 amount) external returns (bool);
}
