// SPDX-License-Identifier: MIT
// Copyright (c) 2025 KLV1, Inc.

pragma solidity ^0.8.20;

interface ILiquidationProxy {
    function setAllowKick(bool _allowKick) external;
    function allowKick() external view returns (bool);
}
