// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Freely mintable token for router and adapter tests.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Unpermissioned on purpose: this stands in for an aToken, which a lending pool burns
    ///      from a holder without an allowance. Test-only.
    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
