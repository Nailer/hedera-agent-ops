// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { HelperConfig, CodeConstants } from "../script/HelperConfig.s.sol";

/**
 * @notice Unit tests for the address book. These run without a fork.
 *
 * The point of these is not to check that a specific address is "correct" — an address book cannot
 * prove that offline. It is to catch the failure modes that actually happen when editing one:
 * a field left at zero, a copy-paste that duplicates a neighbouring line, and a silent
 * zero-struct return for a chain we do not support.
 *
 * Whether the addresses point at live contracts is checked in the fork test.
 */
contract HelperConfigTest is Test, CodeConstants {
    HelperConfig internal helperConfig;

    function setUp() public {
        helperConfig = new HelperConfig();
    }

    function _fields(HelperConfig.NetworkConfig memory cfg) internal pure returns (address[12] memory) {
        return [
            cfg.saucerSwapV2SwapRouter,
            cfg.saucerSwapV2QuoterV2,
            cfg.saucerSwapV2Factory,
            cfg.whbarContract,
            cfg.whbarToken,
            cfg.bonzoLendingPool,
            cfg.bonzoAddressesProvider,
            cfg.bonzoDataProvider,
            cfg.bonzoWethGateway,
            cfg.bonzoPriceOracle,
            cfg.sauceToken,
            cfg.usdcToken
        ];
    }

    function test_TestnetConfigHasNoZeroAddress() public view {
        address[12] memory fields = _fields(helperConfig.getHederaTestnetConfig());
        for (uint256 i = 0; i < fields.length; i++) {
            assertTrue(fields[i] != address(0), "testnet config has a zero address");
        }
    }

    function test_MainnetConfigHasNoZeroAddress() public view {
        address[12] memory fields = _fields(helperConfig.getHederaMainnetConfig());
        for (uint256 i = 0; i < fields.length; i++) {
            assertTrue(fields[i] != address(0), "mainnet config has a zero address");
        }
    }

    /// @dev Catches the classic copy-paste error of repeating the line above.
    function test_TestnetConfigHasNoDuplicateAddress() public view {
        address[12] memory fields = _fields(helperConfig.getHederaTestnetConfig());
        for (uint256 i = 0; i < fields.length; i++) {
            for (uint256 j = i + 1; j < fields.length; j++) {
                assertTrue(fields[i] != fields[j], "testnet config repeats an address");
            }
        }
    }

    function test_MainnetConfigHasNoDuplicateAddress() public view {
        address[12] memory fields = _fields(helperConfig.getHederaMainnetConfig());
        for (uint256 i = 0; i < fields.length; i++) {
            for (uint256 j = i + 1; j < fields.length; j++) {
                assertTrue(fields[i] != fields[j], "mainnet config repeats an address");
            }
        }
    }

    /// @dev Testnet and mainnet must never resolve to the same deployment.
    function test_TestnetAndMainnetDoNotOverlap() public view {
        address[12] memory testnet = _fields(helperConfig.getHederaTestnetConfig());
        address[12] memory mainnet = _fields(helperConfig.getHederaMainnetConfig());
        for (uint256 i = 0; i < testnet.length; i++) {
            assertTrue(testnet[i] != mainnet[i], "testnet and mainnet share an address");
        }
    }

    function test_GetConfigByChainIdResolvesTestnet() public view {
        HelperConfig.NetworkConfig memory cfg = helperConfig.getConfigByChainId(HEDERA_TESTNET_CHAIN_ID);
        assertEq(cfg.bonzoLendingPool, helperConfig.getHederaTestnetConfig().bonzoLendingPool);
    }

    function test_GetConfigByChainIdResolvesMainnet() public view {
        HelperConfig.NetworkConfig memory cfg = helperConfig.getConfigByChainId(HEDERA_MAINNET_CHAIN_ID);
        assertEq(cfg.bonzoLendingPool, helperConfig.getHederaMainnetConfig().bonzoLendingPool);
    }

    /// @dev A zero-filled struct on an unknown chain would surface much later as an opaque revert.
    function test_RevertsOnUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(HelperConfig.HelperConfig__UnsupportedChain.selector, uint256(1)));
        helperConfig.getConfigByChainId(1);
    }

    function testFuzz_RevertsOnAnyUnsupportedChain(uint256 chainId) public {
        vm.assume(chainId != HEDERA_TESTNET_CHAIN_ID && chainId != HEDERA_MAINNET_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(HelperConfig.HelperConfig__UnsupportedChain.selector, chainId));
        helperConfig.getConfigByChainId(chainId);
    }

    /// @dev WHBAR wrapper and WHBAR token are adjacent entities and easy to transpose. Swapping them
    ///      produces swap paths that revert with no useful message, so assert they stay distinct.
    function test_WhbarContractAndTokenAreDistinct() public view {
        HelperConfig.NetworkConfig memory testnet = helperConfig.getHederaTestnetConfig();
        HelperConfig.NetworkConfig memory mainnet = helperConfig.getHederaMainnetConfig();
        assertTrue(testnet.whbarContract != testnet.whbarToken, "testnet WHBAR wrapper == token");
        assertTrue(mainnet.whbarContract != mainnet.whbarToken, "mainnet WHBAR wrapper == token");
    }
}
