//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { HelperConfig } from "./HelperConfig.s.sol";

/**
 * @notice Prints every address and parameter the end-to-end demo needs. Read-only.
 *
 * ```bash
 * forge script script/PrintDemoPlan.s.sol --rpc-url https://testnet.hashio.io/api
 * ```
 *
 * @dev Exists for the same reason as `PrintAssociationPlan`: the demo runner sends transactions with
 * `cast send`, because anything touching the HTS system contract at `0x167` cannot go through
 * `forge script`. Resolution stays here so `HelperConfig` remains the single place a protocol
 * address is written, rather than the runner growing its own copy of the address book.
 *
 * The fee tier is **discovered**, not assumed. SaucerSwap deploys a pool per tier, and on testnet
 * WHBAR/SAUCE exists only at 3000 — 500, 1500, 2500 and 10000 all return the zero address. Writing
 * a tier in by hand would silently produce a swap path pointing at a pool that does not exist.
 */
contract PrintDemoPlan is Script {
    /// @dev Tiers SaucerSwap V2 uses, in the order worth trying.
    uint24[6] private FEE_TIERS = [uint24(3000), 500, 1500, 2500, 10000, 100];

    function run() external {
        HelperConfig.NetworkConfig memory cfg = new HelperConfig().getConfig();

        uint24 fee = _findPoolFee(cfg.saucerSwapV2Factory, cfg.whbarToken, cfg.sauceToken);
        require(fee != 0, "no WHBAR/SAUCE pool at any known fee tier");

        console2.log(string.concat("DEMO whbarContract ", vm.toString(cfg.whbarContract)));
        console2.log(string.concat("DEMO whbarToken ", vm.toString(cfg.whbarToken)));
        console2.log(string.concat("DEMO sauceToken ", vm.toString(cfg.sauceToken)));
        console2.log(string.concat("DEMO swapRouter ", vm.toString(cfg.saucerSwapV2SwapRouter)));
        console2.log(string.concat("DEMO feeTier ", vm.toString(uint256(fee))));
        console2.log(
            string.concat(
                "DEMO pool ", vm.toString(_getPool(cfg.saucerSwapV2Factory, cfg.whbarToken, cfg.sauceToken, fee))
            )
        );
    }

    function _findPoolFee(address factory, address tokenA, address tokenB) private view returns (uint24) {
        for (uint256 i = 0; i < FEE_TIERS.length; i++) {
            if (_getPool(factory, tokenA, tokenB, FEE_TIERS[i]) != address(0)) return FEE_TIERS[i];
        }
        return 0;
    }

    function _getPool(address factory, address tokenA, address tokenB, uint24 fee) private view returns (address) {
        return IUniswapV3FactoryLike(factory).getPool(tokenA, tokenB, fee);
    }
}

interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
