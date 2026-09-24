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

        console2.log(string.concat("PLAN underlyings ", _csv(underlyings)));
        console2.log(string.concat("PLAN atokens ", _csv(aTokens)));
        console2.log(string.concat("PLAN all ", _csv(_concat(underlyings, aTokens))));
    }

    function _csv(address[] memory addresses) private pure returns (string memory csv) {
        for (uint256 i = 0; i < addresses.length; i++) {
            csv = i == 0 ? vm.toString(addresses[i]) : string.concat(csv, ",", vm.toString(addresses[i]));
        }
    }

    function _concat(address[] memory a, address[] memory b) private pure returns (address[] memory joined) {
        joined = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            joined[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            joined[a.length + i] = b[i];
        }
    }
}
