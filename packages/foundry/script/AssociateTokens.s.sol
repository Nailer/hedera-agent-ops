//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { HelperConfig } from "./HelperConfig.s.sol";
import { HtsAssociatable } from "../contracts/HtsAssociatable.sol";
import { IBonzoDataProvider } from "../contracts/interfaces/IBonzoLendingPool.sol";

/**
 * @notice Associates the deployed contracts with every HTS token they will handle.
 *
 * ```bash
 * ACTION_ROUTER=0x... SAUCERSWAP_ADAPTER=0x... BONZO_ADAPTER=0x... \
 *   yarn foundry:deploy --file AssociateTokens.s.sol --network hedera_testnet
 * ```
 *
 * @dev Separate from `DeployAgentOps.s.sol` on purpose. Association is idempotent and safely
 * re-runnable -- HTS returns 194 for an already-associated token and `HtsAssociatable` treats that
 * as success -- whereas deployment is neither. Combined, one transient association failure would
 * force redeploying contracts that were already correct.
 *
 * **Who needs which tokens, and why:**
 *
 * - **Router** — every underlying *and* every aToken. It takes custody of the input on the way in
 *   and the output on the way back, for every action kind. It is the one contract that touches all
 *   of them.
 * - **SaucerSwap adapter** — underlyings only. It receives the input before swapping, but output
 *   goes straight to the router, so it never holds an aToken.
 * - **Bonzo adapter** — underlyings *and* aTokens. Supply hands it an underlying; Withdraw hands it
 *   aTokens to burn.
 *
 * The agent's own treasury also needs associating with anything it will hold. That is the operator's
 * account, not ours, so it is out of scope here and called out in the README instead.
 *
 * aToken addresses are resolved from Bonzo's live data provider rather than hardcoded, so this stays
 * correct if a reserve is redeployed.
 */
contract AssociateTokens is Script {
    error AssociateTokens__MissingEnv(string name);

    function run() external {
        HelperConfig.NetworkConfig memory cfg = new HelperConfig().getConfig();

        address router = _requireEnv("ACTION_ROUTER");
        address saucerSwapAdapter = _requireEnv("SAUCERSWAP_ADAPTER");
        address bonzoAdapter = _requireEnv("BONZO_ADAPTER");

        address[] memory underlyings = new address[](3);
        underlyings[0] = cfg.whbarToken;
        underlyings[1] = cfg.sauceToken;
        underlyings[2] = cfg.usdcToken;

        address[] memory aTokens = _resolveATokens(cfg.bonzoDataProvider, underlyings);

        console2.log("Associating on chain", block.chainid);

        vm.startBroadcast();

        // Router: everything, because it custodies both legs of every action.
        HtsAssociatable(router).associateMany(underlyings);
        HtsAssociatable(router).associateMany(aTokens);
        console2.log("  router associated with underlyings + aTokens");

        // SaucerSwap adapter: inputs only; output is delivered to the router.
        HtsAssociatable(saucerSwapAdapter).associateMany(underlyings);
        console2.log("  SaucerSwap adapter associated with underlyings");

        // Bonzo adapter: underlyings for Supply/Repay, aTokens for Withdraw.
        HtsAssociatable(bonzoAdapter).associateMany(underlyings);
        HtsAssociatable(bonzoAdapter).associateMany(aTokens);
        console2.log("  Bonzo adapter associated with underlyings + aTokens");

        vm.stopBroadcast();

        console2.log("Done. Remember the agent treasury needs its own associations.");
    }

    /// @dev Resolves each underlying's aToken from the live data provider.
    function _resolveATokens(address dataProvider, address[] memory underlyings)
        private
        view
        returns (address[] memory aTokens)
    {
        aTokens = new address[](underlyings.length);
        for (uint256 i = 0; i < underlyings.length; i++) {
            (address aToken,,) = IBonzoDataProvider(dataProvider).getReserveTokensAddresses(underlyings[i]);
            require(aToken != address(0), "reserve is not listed on Bonzo");
            aTokens[i] = aToken;
        }
    }

    /// @dev Fails by name rather than associating the zero address.
    function _requireEnv(string memory name) private view returns (address value) {
        value = vm.envOr(name, address(0));
        if (value == address(0)) revert AssociateTokens__MissingEnv(name);
    }
}
