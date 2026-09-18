// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { htsSetup } from "hedera-forking/htsSetup.sol";
import { HelperConfig, CodeConstants } from "../../script/HelperConfig.s.sol";

/**
 * @notice Fork tests that prove every address in the book points at live code.
 *
 * Run with:
 *   yarn foundry:test:testnet
 *   yarn foundry:test:mainnet
 *
 * These skip themselves under a plain `yarn foundry:test`, so the default suite — and therefore CI —
 * stays hermetic and does not depend on a public RPC being up.
 *
 * An address book that compiles but points at empty accounts is the failure this catches. On Hedera
 * it is a live risk: long-zero addresses are derived from entity numbers, so a typo yields a
 * perfectly well-formed address for an entity that is not a contract, or does not exist.
 */
contract HelperConfigForkTest is Test, CodeConstants {
    HelperConfig internal helperConfig;

    function setUp() public {
        helperConfig = new HelperConfig();

        // Every reserve Bonzo lists is an HTS token, not an ERC20 contract. Reading `symbol()` or
        // `balanceOf()` on one routes through the HTS system contract at 0x167, which does not exist
        // in a plain EVM fork — the call lands on empty code and dies with InvalidFEOpcode.
        //
        // htsSetup() etches a Solidity HTS emulator at 0x167 that services those calls by querying
        // the mirror node over ffi. Only meaningful when actually forked, so it is gated on chain ID.
        if (block.chainid == HEDERA_TESTNET_CHAIN_ID || block.chainid == HEDERA_MAINNET_CHAIN_ID) {
            htsSetup();
        }
    }

    modifier onlyOnChain(uint256 chainId) {
        if (block.chainid != chainId) {
            vm.skip(true);
        }
        _;
    }

    function _assertHasCode(address target, string memory label) internal view {
        assertTrue(target.code.length > 0, string.concat(label, " has no code on this chain"));
    }

    function _assertConfigIsLive(HelperConfig.NetworkConfig memory cfg) internal view {
        _assertHasCode(cfg.saucerSwapV2SwapRouter, "SaucerSwapV2SwapRouter");
        _assertHasCode(cfg.saucerSwapV2QuoterV2, "SaucerSwapV2QuoterV2");
        _assertHasCode(cfg.saucerSwapV2Factory, "SaucerSwapV2Factory");
        _assertHasCode(cfg.whbarContract, "WHBAR contract");
        _assertHasCode(cfg.bonzoLendingPool, "Bonzo LendingPool");
        _assertHasCode(cfg.bonzoAddressesProvider, "Bonzo LendingPoolAddressesProvider");
        _assertHasCode(cfg.bonzoDataProvider, "Bonzo AaveProtocolDataProvider");
        _assertHasCode(cfg.bonzoWethGateway, "Bonzo WETHGateway");
        _assertHasCode(cfg.bonzoPriceOracle, "Bonzo AaveOracle");
    }

    function test_TestnetAddressesAreLive() public onlyOnChain(HEDERA_TESTNET_CHAIN_ID) {
        _assertConfigIsLive(helperConfig.getHederaTestnetConfig());
    }

    function test_MainnetAddressesAreLive() public onlyOnChain(HEDERA_MAINNET_CHAIN_ID) {
        _assertConfigIsLive(helperConfig.getHederaMainnetConfig());
    }

    /**
     * @dev The strongest check available offline: ask Bonzo itself which reserves it lists, and
     *      confirm the tokens we hardcoded appear in that list. This catches a stale address book
     *      after a protocol redeploys, which `code.length > 0` alone would not.
     */
    function test_TestnetReserveTokensAreListedByBonzo() public onlyOnChain(HEDERA_TESTNET_CHAIN_ID) {
        HelperConfig.NetworkConfig memory cfg = helperConfig.getHederaTestnetConfig();
        IProtocolDataProvider provider = IProtocolDataProvider(cfg.bonzoDataProvider);
        IProtocolDataProvider.TokenData[] memory reserves = provider.getAllReservesTokens();

        assertTrue(_contains(reserves, cfg.sauceToken), "SAUCE is not a listed Bonzo reserve");
        assertTrue(_contains(reserves, cfg.usdcToken), "USDC is not a listed Bonzo reserve");
        assertTrue(_contains(reserves, cfg.whbarToken), "WHBAR token is not a listed Bonzo reserve");
    }

    function test_MainnetReserveTokensAreListedByBonzo() public onlyOnChain(HEDERA_MAINNET_CHAIN_ID) {
        HelperConfig.NetworkConfig memory cfg = helperConfig.getHederaMainnetConfig();
        IProtocolDataProvider provider = IProtocolDataProvider(cfg.bonzoDataProvider);
        IProtocolDataProvider.TokenData[] memory reserves = provider.getAllReservesTokens();

        assertTrue(_contains(reserves, cfg.sauceToken), "SAUCE is not a listed Bonzo reserve");
        assertTrue(_contains(reserves, cfg.usdcToken), "USDC is not a listed Bonzo reserve");
        assertTrue(_contains(reserves, cfg.whbarToken), "WHBAR token is not a listed Bonzo reserve");
    }

    function _contains(IProtocolDataProvider.TokenData[] memory reserves, address token) private pure returns (bool) {
        for (uint256 i = 0; i < reserves.length; i++) {
            if (reserves[i].tokenAddress == token) return true;
        }
        return false;
    }
}

/// @notice Minimal view of Bonzo's Aave v2 style data provider.
interface IProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    function getAllReservesTokens() external view returns (TokenData[] memory);
}
