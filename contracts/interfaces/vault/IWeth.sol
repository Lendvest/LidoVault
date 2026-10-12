// SPDX-License-Identifier: MIT
// Copyright (c) 2025 KLV1, Inc.

pragma solidity ^0.8.20;

interface IWeth {
    function withdraw(uint256 amount) external;
    function deposit() external payable;
}
