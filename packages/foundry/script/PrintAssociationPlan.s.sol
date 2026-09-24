//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { HelperConfig } from "./HelperConfig.s.sol";
import { IBonzoDataProvider } from "../contracts/interfaces/IBonzoLendingPool.sol";

/**
 * @notice Prints which tokens each deployed contract needs to be associated with. Read-only.
 *
 * ```bash
 * forge script script/PrintAssociationPlan.s.sol --rpc-url https://testnet.hashio.io/api
 * ```
 *
 * @dev **This exists because `forge script` cannot perform the association itself.**
 *
 * Association calls the HTS system contract at `0x167`, and forge always executes a script's body
 * locally to discover which transactions to broadcast. The local EVM has no `0x167`, so the call
 * dies with `InvalidFEOpcode` before anything is sent. `--skip-simulation` does not help: it skips
 * the on-chain simulation, not the local execution that finds the transactions. Verified — the
 * script fails identically with no broadcast flag at all.
 *
 * So the work is split. This script does the part forge is good at: resolving addresses, with
 * `HelperConfig` remaining the single place any protocol address is written. `scripts-js/associateTokens.js`
 * then sends the transactions with `cast send`, which signs and submits without executing locally.
 *
 * Output is deliberately machine-readable — `PLAN <label> <csv>` — so the runner parses it rather
 * than duplicating the address book in JavaScript.
 *
 * **Only the underlyings are associable.** Bonzo's aTokens are ordinary ERC20 contracts deployed
 * through the EVM, not HTS tokens: `0xf594C3d2…` resolves as contract `0.0.4999408` on the mirror
 * node and is rejected by `/api/v1/tokens/`. Associating one fails with HTS response code 167,
 * `INVALID_TOKEN_ID`, and takes the whole transaction with it. Nor is it needed — ERC20 balances
 * require no association. The aToken list is still printed, because knowing which addresses are
 * *not* HTS is worth having, but nothing should try to associate them.
 */
contract PrintAssociationPlan is Script {
    function run() external {
        HelperConfig.NetworkConfig memory cfg = new HelperConfig().getConfig();

        address[] memory underlyings = new address[](3);
        underlyings[0] = cfg.whbarToken;
        underlyings[1] = cfg.sauceToken;
        underlyings[2] = cfg.usdcToken;

        address[] memory aTokens = new address[](underlyings.length);
        for (uint256 i = 0; i < underlyings.length; i++) {
            (address aToken,,) = IBonzoDataProvider(cfg.bonzoDataProvider).getReserveTokensAddresses(underlyings[i]);
            require(aToken != address(0), "reserve is not listed on Bonzo");
            aTokens[i] = aToken;
        }

        // `associable` is what the runner acts on. The aTokens are reported for visibility only.
        console2.log(string.concat("PLAN associable ", _csv(underlyings)));
        console2.log(string.concat("PLAN erc20_atokens_not_associable ", _csv(aTokens)));
    }

    function _csv(address[] memory addresses) private pure returns (string memory csv) {
        for (uint256 i = 0; i < addresses.length; i++) {
            csv = i == 0 ? vm.toString(addresses[i]) : string.concat(csv, ",", vm.toString(addresses[i]));
        }
    }
}
