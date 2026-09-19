// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { htsSetup } from "hedera-forking/htsSetup.sol";
import { SaucerSwapAdapter } from "../../contracts/adapters/SaucerSwapAdapter.sol";
import { ISaucerSwapV2Quoter } from "../../contracts/interfaces/ISaucerSwapV2Router.sol";
import { IAgentAction } from "../../contracts/interfaces/IAgentAction.sol";
import { HelperConfig, CodeConstants } from "../../script/HelperConfig.s.sol";

/**
 * @notice Proves the adapter's path encoding is the encoding SaucerSwap actually accepts.
 *
 * Run with `yarn foundry:test:testnet`; self-skips under the hermetic suite.
 *
 * A unit test against a mock proves only that we are self-consistent. The mock was written from the
 * same reading of the docs as the adapter, so if that reading were wrong both would agree and both
 * would be wrong. This asks the live QuoterV2 instead: if the 43-byte layout, the fee-tier width, or
 * the byte order were off, the real contract would revert or return nothing.
 *
 * Quoting is read-only, so this needs no funded account and no token association.
 *
 * These run against a public RPC and mirror node that rate-limit, and the HTS emulator issues one
 * ffi fetch per piece of token state it needs. Keep the number of quote calls in this file small:
 * they are the expensive operation, and enough of them in one run will start failing with a bare
 * "Unexpected error" that looks like a contract bug and is not. This is a further reason fork tests
 * stay out of CI.
 */
contract SaucerSwapAdapterForkTest is Test, CodeConstants {
    HelperConfig internal helperConfig;
    HelperConfig.NetworkConfig internal cfg;

    /// @dev The WHBAR/SAUCE tier that exists on testnet. Discovered from the factory below rather
    ///      than trusted, so a retired pool surfaces as a clear failure.
    uint24 internal constant FEE_3000 = 3000;

    function setUp() public {
        helperConfig = new HelperConfig();
        if (block.chainid == HEDERA_TESTNET_CHAIN_ID) {
            cfg = helperConfig.getHederaTestnetConfig();
            // Quoting reaches into the pool, which reads its HTS token balances through 0x167.
            // That system contract does not exist in a plain EVM fork, so without this the call
            // consumes all gas and dies with an "Unexpected error" that names nothing useful.
            // Note `cast call` against the real network succeeds here -- only the fork needs this.
            htsSetup();
        }
    }

    modifier onlyTestnet() {
        if (block.chainid != HEDERA_TESTNET_CHAIN_ID) {
            vm.skip(true);
        }
        _;
    }

    function _path(address tokenIn, uint24 fee, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, fee, tokenOut);
    }

    /// @dev The layout the adapter validates: 20 + 3 + 20.
    function test_PathEncodingIsFortyThreeBytes() public onlyTestnet {
        bytes memory path = _path(cfg.whbarToken, FEE_3000, cfg.sauceToken);
        assertEq(path.length, 43, "single-hop path must be 20 + 3 + 20 bytes");
    }

    /// @dev Confirms the pool this test quotes against is really deployed.
    function test_WhbarSaucePoolExistsOnTestnet() public onlyTestnet {
        address pool = IUniswapV3FactoryLike(cfg.saucerSwapV2Factory).getPool(cfg.whbarToken, cfg.sauceToken, FEE_3000);
        assertTrue(pool != address(0), "WHBAR/SAUCE 0.3% pool is not deployed on testnet");
        assertTrue(pool.code.length > 0, "pool address has no code");
    }

    /**
     * @dev The real check. A wrong encoding does not produce a small number here, it produces a
     *      revert or a zero — which is what makes this worth the RPC round trip.
     *
     *      Both directions are asserted in a single test on purpose. `setUp` runs `htsSetup()`
     *      before every test function, and each quote fans out into many mirror-node fetches over
     *      ffi, so splitting these across two tests doubles the load on a public endpoint that
     *      rate-limits. Doing that made the pair fail intermittently while each passed in
     *      isolation. Quote calls are the expensive thing here; keep them in one place.
     */
    function test_LiveQuoterAcceptsOurPathEncodingBothDirections() public onlyTestnet {
        // WHBAR carries 8 decimals, SAUCE 6.
        bytes memory forwardPath = _path(cfg.whbarToken, FEE_3000, cfg.sauceToken);
        (uint256 forwardOut,,,) = ISaucerSwapV2Quoter(cfg.saucerSwapV2QuoterV2).quoteExactInput(forwardPath, 1e8);
        assertGt(forwardOut, 0, "live quoter returned nothing for WHBAR -> SAUCE");

        // Reversing the path must also quote. Byte order is meaningful, so this rules out our
        // encoding being accidentally symmetric.
        bytes memory reversePath = _path(cfg.sauceToken, FEE_3000, cfg.whbarToken);
        (uint256 reverseOut,,,) = ISaucerSwapV2Quoter(cfg.saucerSwapV2QuoterV2).quoteExactInput(reversePath, 1e6);
        assertGt(reverseOut, 0, "live quoter returned nothing for SAUCE -> WHBAR");
    }

    /// @dev The adapter accepts a path whose endpoints match the request. Reaching the malformed /
    ///      mismatch guards is what is under test, so the swap itself is never attempted.
    function test_AdapterAcceptsARealTestnetPath() public onlyTestnet {
        SaucerSwapAdapter adapter = new SaucerSwapAdapter(address(this), cfg.saucerSwapV2SwapRouter);
        bytes memory path = _path(cfg.whbarToken, FEE_3000, cfg.sauceToken);

        IAgentAction.ActionRequest memory request = IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Swap,
            assetIn: cfg.whbarToken,
            amountIn: 1e8,
            assetOut: cfg.sauceToken,
            minAmountOut: 0,
            protocolData: abi.encode(path, block.timestamp + 600)
        });

        // This adapter holds no WHBAR and is not associated, so the call cannot succeed. What
        // matters is that it fails past validation rather than at it.
        try adapter.execute(request, address(this)) {
        // A success would mean the environment funded us; equally fine for this assertion.
        }
        catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != SaucerSwapAdapter.SaucerSwapAdapter__MalformedPath.selector
                    && selector != SaucerSwapAdapter.SaucerSwapAdapter__PathInputMismatch.selector
                    && selector != SaucerSwapAdapter.SaucerSwapAdapter__PathOutputMismatch.selector,
                "a real testnet path was rejected by the adapter's own validation"
            );
        }
    }
}

/// @notice `getPool` as exposed by the SaucerSwap V2 factory.
interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
