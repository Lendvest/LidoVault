// SPDX-License-Identifier: BUSL-1.1
// Author: Lendvest

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LVToken
 * @notice A simple ERC20 token modified to use an allowlist (onlyAllowed) instead of Ownable for mint control.
 */
contract LVToken is ERC20, Ownable {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {}

    /**
     * @dev Mint new tokens.
     * Can only be called by Ownable addresses.
     */
    function mint(address to, uint256 amount) public onlyOwner returns (bool) {
        _mint(to, amount);
        return true;
    }

    /**
     * @dev Burn tokens from the sender's account.
     * Can only be called by Ownable addresses.
     */
    function burn(address from, uint256 amount) public onlyOwner returns (bool) {
        _burn(from, amount);
        return true;
    }
}
