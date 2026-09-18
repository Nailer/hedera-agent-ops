// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";

/**
 * @title CodeConstants
 * @notice Chain IDs this template targets. Hedera exposes two EVM chains.
 */
abstract contract CodeConstants {
    /// @notice Hedera mainnet EVM chain ID.
    uint256 public constant HEDERA_MAINNET_CHAIN_ID = 295;

    /// @notice Hedera testnet EVM chain ID.
    uint256 public constant HEDERA_TESTNET_CHAIN_ID = 296;
}

/**
 * @title HelperConfig
 * @notice Single source of truth for every external protocol address this template depends on.
 *
 * Addresses were taken from each protocol's published deployment page and then verified against
 * the Hedera mirror node (`/api/v1/contracts/{id}` -> `evm_address`) on 2026-09-18. The Bonzo
 * reserve lists were additionally read on-chain from `AaveProtocolDataProvider.getAllReservesTokens()`
 * rather than copied from documentation, because the docs page lists mainnet assets only.
 *
 * Two address shapes appear here and the difference is not cosmetic:
 *
 *  - SaucerSwap contracts were created through HAPI, so they have no EVM-native address and the
 *    mirror node reports the "long-zero" form (`0x00..00` + the entity number in hex).
 *    `0.0.1414040` -> `0x0000000000000000000000000000000000159398`.
 *  - Bonzo contracts were deployed through the EVM, so they carry ordinary keccak-derived
 *    addresses such as `0xf67DBe9bD1B331cA379c44b5562EAa1CE831EbC2`.
 *
 * Both are callable from Solidity. Never hand-derive a long-zero address: resolve it from the
 * mirror node, because an account that has since been given an EVM alias will not match.
 *
 * WHBAR is the seam between the two protocols. SaucerSwap's WHBAR token (`0.0.15058`) is the same
 * token Bonzo lists as its WHBAR reserve, which is what lets one agent swap on SaucerSwap and
 * supply the proceeds to Bonzo without an intermediate bridge.
 */
contract HelperConfig is CodeConstants, Script {
    error HelperConfig__UnsupportedChain(uint256 chainId);

    /**
     * @param saucerSwapV2SwapRouter SaucerSwap V2 router — `exactInput` / `exactOutput`.
     * @param saucerSwapV2QuoterV2 Gas-free quotes; `quoteExactInput` is `nonpayable`, so it must
     *        be simulated rather than called as a `view`.
     * @param saucerSwapV2Factory Creates and resolves V2 pools via `getPool`.
     * @param whbarContract The WHBAR wrapper contract (deposit / withdraw).
     * @param whbarToken The WHBAR HTS token. This is the address that appears in swap paths and
     *        as a Bonzo reserve — not `whbarContract`.
     * @param bonzoLendingPool Aave v2 style pool — `deposit`, `withdraw`, `borrow`, `repay`.
     * @param bonzoAddressesProvider Registry that resolves the current pool implementation.
     * @param bonzoDataProvider Reserve and user-position reads.
     * @param bonzoWethGateway Wraps native HBAR so it can be supplied without a manual wrap step.
     * @param bonzoPriceOracle Aave oracle used for health-factor math.
     * @param sauceToken SAUCE — a Bonzo reserve and a liquid SaucerSwap pair.
     * @param usdcToken USDC — a Bonzo reserve, used as the stable leg in examples.
     */
    struct NetworkConfig {
        address saucerSwapV2SwapRouter;
        address saucerSwapV2QuoterV2;
        address saucerSwapV2Factory;
        address whbarContract;
        address whbarToken;
        address bonzoLendingPool;
        address bonzoAddressesProvider;
        address bonzoDataProvider;
        address bonzoWethGateway;
        address bonzoPriceOracle;
        address sauceToken;
        address usdcToken;
    }

    /// @notice Returns the config for the chain this script is running against.
    function getConfig() public view returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    /// @notice Returns the config for an explicit chain ID.
    /// @dev Reverts rather than returning a zero-filled struct, so a misconfigured fork fails loudly.
    function getConfigByChainId(uint256 chainId) public pure returns (NetworkConfig memory) {
        if (chainId == HEDERA_TESTNET_CHAIN_ID) return getHederaTestnetConfig();
        if (chainId == HEDERA_MAINNET_CHAIN_ID) return getHederaMainnetConfig();
        revert HelperConfig__UnsupportedChain(chainId);
    }

    /// @notice Hedera testnet (296).
    function getHederaTestnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            // SaucerSwap — HAPI-created, long-zero addresses.
            saucerSwapV2SwapRouter: 0x0000000000000000000000000000000000159398, // 0.0.1414040
            saucerSwapV2QuoterV2: 0x00000000000000000000000000000000001535B2, // 0.0.1390002
            saucerSwapV2Factory: 0x00000000000000000000000000000000001243eE, // 0.0.1197038
            whbarContract: 0x0000000000000000000000000000000000003aD1, // 0.0.15057
            whbarToken: 0x0000000000000000000000000000000000003aD2, // 0.0.15058
            // Bonzo — EVM-deployed, keccak-derived addresses.
            bonzoLendingPool: 0xf67DBe9bD1B331cA379c44b5562EAa1CE831EbC2, // 0.0.4999355
            bonzoAddressesProvider: 0x873575d4AeeBe015AcF3BB17AAa9DD248cc76D68, // 0.0.4999346
            bonzoDataProvider: 0x121A2AFFA5f595175E60E01EAeF0deC43Cc3b024, // 0.0.4999382
            bonzoWethGateway: 0x16197Ef10F26De77C9873d075f8774BdEc20A75d, // 0.0.4999384
            bonzoPriceOracle: 0x9B940a1e60D652bCaf09C1d2224d1A4a544FDFb0, // 0.0.4999377 (AaveOracle)
            // Reserve tokens, read from getAllReservesTokens() on testnet.
            sauceToken: 0x0000000000000000000000000000000000120f46, // 0.0.1183558
            usdcToken: 0x0000000000000000000000000000000000001549 // 0.0.5449
        });
    }

    /// @notice Hedera mainnet (295).
    function getHederaMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            saucerSwapV2SwapRouter: 0x00000000000000000000000000000000003c437A, // 0.0.3949434
            saucerSwapV2QuoterV2: 0x00000000000000000000000000000000003c4370, // 0.0.3949424
            saucerSwapV2Factory: 0x00000000000000000000000000000000003c3951, // 0.0.3946833
            whbarContract: 0x0000000000000000000000000000000000163B59, // 0.0.1456985
            whbarToken: 0x0000000000000000000000000000000000163B5a, // 0.0.1456986
            bonzoLendingPool: 0x236897c518996163E7b313aD21D1C9fCC7BA1afc, // 0.0.7308459
            bonzoAddressesProvider: 0x76b846DAB3646527bfb75952E1f33AfAA72B56D1, // 0.0.7308451
            bonzoDataProvider: 0x78feDC4D7010E409A0c0c7aF964cc517D3dCde18, // 0.0.7308483
            bonzoWethGateway: 0x9a601543e9264255BebB20Cef0E7924e97127105, // 0.0.7308485
            bonzoPriceOracle: 0xc0Bb4030b55093981700559a0B751DCf7Db03cBB, // 0.0.7308480 (AaveOracle)
            sauceToken: 0x00000000000000000000000000000000000b2aD5, // 0.0.731861
            usdcToken: 0x000000000000000000000000000000000006f89a // 0.0.456858
        });
    }
}
