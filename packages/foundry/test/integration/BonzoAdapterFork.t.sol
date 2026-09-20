// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { BonzoAdapter } from "../../contracts/adapters/BonzoAdapter.sol";
import { IBonzoDataProvider } from "../../contracts/interfaces/IBonzoLendingPool.sol";
import { IAgentAction } from "../../contracts/interfaces/IAgentAction.sol";
import { HelperConfig, CodeConstants } from "../../script/HelperConfig.s.sol";

/**
 * @notice Proves the adapter's view of Bonzo matches the live deployment.
 *
 * Run with `yarn foundry:test:testnet`; self-skips under the hermetic suite.
 *
 * The unit tests use a mock reserve registry that we wrote, so they prove the adapter is consistent
 * with our own model of Bonzo. They cannot detect that model being wrong. These tests ask the real
 * data provider which aToken belongs to which reserve, and confirm the aToken agrees by pointing
 * back at the same underlying.
 *
 * Deliberately no `htsSetup()` here: reserve metadata is plain contract storage, not token balance
 * state, so nothing routes through `0x167`. That keeps these fast and keeps them off the
 * rate-limited mirror node. If a test added here starts reading balances, it will need the emulator
 * and will slow down accordingly -- see AGENTS.md.
 */
contract BonzoAdapterForkTest is Test, CodeConstants {
    HelperConfig internal helperConfig;
    HelperConfig.NetworkConfig internal cfg;

    function setUp() public {
        helperConfig = new HelperConfig();
        if (block.chainid == HEDERA_TESTNET_CHAIN_ID) {
            cfg = helperConfig.getHederaTestnetConfig();
        }
    }

    modifier onlyTestnet() {
        if (block.chainid != HEDERA_TESTNET_CHAIN_ID) {
            vm.skip(true);
        }
        _;
    }

    /**
     * @dev Every reserve the template names must resolve to an aToken that points back at it.
     *      A one-way lookup could be satisfied by a stale or unrelated address; the round trip is
     *      what makes this meaningful.
     */
    function test_ReserveTokensRoundTripOnLiveBonzo() public onlyTestnet {
        address[3] memory reserves = [cfg.sauceToken, cfg.usdcToken, cfg.whbarToken];
        string[3] memory labels = ["SAUCE", "USDC", "WHBAR"];

        for (uint256 i = 0; i < reserves.length; i++) {
            (address aToken,,) = IBonzoDataProvider(cfg.bonzoDataProvider).getReserveTokensAddresses(reserves[i]);

            assertTrue(aToken != address(0), string.concat(labels[i], " is not a listed Bonzo reserve"));
            assertTrue(aToken.code.length > 0, string.concat(labels[i], " aToken has no code"));

            address underlying = IAToken(aToken).UNDERLYING_ASSET_ADDRESS();
            assertEq(underlying, reserves[i], string.concat(labels[i], " aToken points at a different underlying"));
        }
    }

    /// @dev An address Bonzo does not list must resolve to zero, which is what the adapter's
    ///      `ReserveNotListed` guard relies on.
    function test_UnlistedAssetResolvesToZeroOnLiveBonzo() public onlyTestnet {
        address notAReserve = address(0xdead);
        (address aToken,,) = IBonzoDataProvider(cfg.bonzoDataProvider).getReserveTokensAddresses(notAReserve);
        assertEq(aToken, address(0), "an unlisted asset must resolve to the zero address");
    }

    /**
     * @dev The adapter, pointed at the real deployment, rejects an unlisted reserve with its own
     *      named error rather than failing somewhere inside Bonzo.
     */
    function test_AdapterRejectsUnlistedReserveAgainstLiveBonzo() public onlyTestnet {
        BonzoAdapter adapter = new BonzoAdapter(address(this), cfg.bonzoLendingPool, cfg.bonzoDataProvider);

        IAgentAction.ActionRequest memory request = IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Supply,
            assetIn: address(0xdead),
            amountIn: 1e6,
            assetOut: cfg.sauceToken,
            minAmountOut: 0,
            protocolData: ""
        });

        vm.expectRevert(abi.encodeWithSelector(BonzoAdapter.BonzoAdapter__ReserveNotListed.selector, address(0xdead)));
        adapter.execute(request, address(this));
    }

    /// @dev The adapter resolves the same aToken the live data provider does, so a Supply request
    ///      built from real addresses passes validation.
    function test_AdapterAgreesWithLiveBonzoOnTheAToken() public onlyTestnet {
        BonzoAdapter adapter = new BonzoAdapter(address(this), cfg.bonzoLendingPool, cfg.bonzoDataProvider);
        (address aToken,,) = IBonzoDataProvider(cfg.bonzoDataProvider).getReserveTokensAddresses(cfg.sauceToken);

        IAgentAction.ActionRequest memory request = IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Supply,
            assetIn: cfg.sauceToken,
            amountIn: 1e6,
            assetOut: aToken,
            minAmountOut: 0,
            protocolData: ""
        });

        // The adapter holds no SAUCE and is not associated, so this cannot complete. What is under
        // test is that it fails past asset validation rather than at it.
        try adapter.execute(request, address(this)) {
        // Succeeding would mean the environment funded us; fine for this assertion.
        }
        catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != BonzoAdapter.BonzoAdapter__AssetOutIsNotTheAToken.selector
                    && selector != BonzoAdapter.BonzoAdapter__ReserveNotListed.selector,
                "a request built from live Bonzo addresses was rejected by the adapter's own validation"
            );
        }
    }
}

/// @notice The aToken's back-reference to its underlying reserve.
interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
