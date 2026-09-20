// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice The slice of Bonzo's lending pool this template uses.
 *
 * @dev Bonzo is an Aave **v2** fork, verified against the live testnet deployment rather than
 *      assumed: `getReserveData` returns the v2 struct shape, and the contracts are named
 *      `LendingPool` / `LendingPoolAddressesProvider` rather than v3's `Pool`. That distinction
 *      decides the deposit entry point — v2 is `deposit`, v3 renamed it `supply`. Reaching for the
 *      v3 name here produces a call to a function that does not exist.
 */
interface IBonzoLendingPool {
    /// @notice Supply `amount` of `asset`, minting aTokens to `onBehalfOf`.
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Burn the caller's aTokens and send `amount` of the underlying `asset` to `to`.
    /// @return The amount actually withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Repay `onBehalfOf`'s debt in `asset`.
    /// @param rateMode 1 = stable, 2 = variable.
    /// @return The amount actually repaid, which is capped at the outstanding debt.
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
}

/// @notice Reserve metadata reads. Used to resolve the aToken for a reserve rather than trusting a
///         caller-declared address.
interface IBonzoDataProvider {
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}
