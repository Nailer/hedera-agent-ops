//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";
import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { HelperConfig, CodeConstants } from "./HelperConfig.s.sol";
import { AgentRegistry } from "../contracts/AgentRegistry.sol";
import { ActionRouter } from "../contracts/ActionRouter.sol";
import { SaucerSwapAdapter } from "../contracts/adapters/SaucerSwapAdapter.sol";
import { BonzoAdapter } from "../contracts/adapters/BonzoAdapter.sol";

/**
 * @notice Deploys and wires the whole system.
 *
 * ```bash
 * yarn foundry:deploy --file DeployAgentOps.s.sol --network hedera_testnet
 * ```
 *
 * @dev **Deployment and token association are separate scripts, deliberately.** Association is
 * idempotent and safely re-runnable; deployment is neither. Folding them together would mean a
 * single failed association -- a token not yet funded, a transient HTS error -- forces a redeploy
 * of contracts that were already fine. Run `AssociateTokens.s.sol` after this.
 *
 * **Every external address comes from `HelperConfig`.** No address literals here, per the
 * invariant. On an unsupported chain `HelperConfig` reverts by name rather than handing back a
 * zero-filled struct, so deploying somewhere the protocols do not exist fails immediately instead
 * of producing a system wired to nothing.
 *
 * **Wiring is asserted before the run is allowed to finish.** A deploy that silently half-wires is
 * worse than one that fails: the contracts exist, the frontend finds them, and the first agent
 * action reverts somewhere unhelpful. The checks at the end cost nothing and turn that into an
 * immediate, named failure.
 */
contract DeployAgentOps is ScaffoldETHDeploy, CodeConstants {
    /// @dev `HelperConfig` is instantiated here, outside the broadcast in `_deploy`, so it is not
    ///      itself deployed on-chain. It holds no state worth persisting -- it is an address book.
    function run() external {
        HelperConfig.NetworkConfig memory cfg = new HelperConfig().getConfig();
        _deploy(cfg);
        _exportDeployments();
    }

    /**
     * @dev Writes `deployments/<chainId>.json` without going near `ScaffoldETHDeploy.exportDeployments`.
     *
     * That inherited version calls `findChainName()` when `vm.getChain(block.chainid)` fails, and it
     * fails here: Hedera's 296 is not in Foundry's built-in chain list, so it reverts with "invalid
     * chain alias". `findChainName` then loops over `vm.rpcUrls()` calling **`vm.createSelectFork`**,
     * switching the active fork part-way through the script.
     *
     * Under `--broadcast` forge walks the script to collect transactions and then executes them, so a
     * fork switch in between discards the state the script contract's nonce was tracked against. The
     * next `new` is then computed from a stale script nonce and dies with `CreateCollision` — which is
     * what a real deploy hit, at the script contract's own nonce-2 address rather than the
     * broadcaster's. A plain simulation never shows it, because there is no second pass.
     *
     * The chain name is resolved from the chain id directly. There is nothing to discover: this
     * template targets exactly two networks and `HelperConfig` has already rejected anything else.
     */
    function _exportDeployments() internal {
        // The first argument to `serializeString` is the *object key* -- a stable handle naming the
        // JSON object being built -- not the accumulated document. It must stay constant across the
        // loop. Reassigning it from the return value starts a new object on every iteration, and
        // only the final entry survives into the file.
        string memory objectKey = "agentOpsDeployments";

        for (uint256 i = 0; i < deployments.length; i++) {
            vm.serializeString(objectKey, vm.toString(deployments[i].addr), deployments[i].name);
        }
        string memory json = vm.serializeString(objectKey, "networkName", _chainName());

        string memory dir = string.concat(vm.projectRoot(), "/deployments/");
        vm.createDir(dir, true);
        vm.writeJson(json, string.concat(dir, vm.toString(block.chainid), ".json"));
    }

    function _chainName() private view returns (string memory) {
        if (block.chainid == HEDERA_TESTNET_CHAIN_ID) return "hedera_testnet";
        if (block.chainid == HEDERA_MAINNET_CHAIN_ID) return "hedera_mainnet";
        // Unreachable: HelperConfig.getConfig() reverts on any other chain before this runs.
        return vm.toString(block.chainid);
    }

    function _deploy(HelperConfig.NetworkConfig memory cfg) internal {
        deployer = _startBroadcast();
        if (deployer == address(0)) revert InvalidPrivateKey("Invalid private key");

        _deployAndWire(cfg);

        _stopBroadcast();
    }

    function _deployAndWire(HelperConfig.NetworkConfig memory cfg) private {
        console2.log("Deploying Hedera Agent Ops");
        console2.log("  chain id :", block.chainid);
        console2.log("  deployer :", deployer);

        // 1. Registry. The deployer owns it, and owning it means being able to point it at a
        //    router. It does not confer any authority over individual agents -- each agent's
        //    controller holds that.
        AgentRegistry registry = new AgentRegistry(deployer);
        deployments.push(Deployment({ name: "AgentRegistry", addr: address(registry) }));
        console2.log("  AgentRegistry      :", address(registry));

        // 2. Router, bound to the registry for the life of the contract.
        ActionRouter router = new ActionRouter(deployer, address(registry));
        deployments.push(Deployment({ name: "ActionRouter", addr: address(router) }));
        console2.log("  ActionRouter       :", address(router));

        // 3. The registry only accepts spend accounting from this one address.
        registry.setActionRouter(address(router));

        // 4. Adapters. Each is inert until the router allowlists it below.
        SaucerSwapAdapter saucerSwapAdapter = new SaucerSwapAdapter(deployer, cfg.saucerSwapV2SwapRouter);
        deployments.push(Deployment({ name: "SaucerSwapAdapter", addr: address(saucerSwapAdapter) }));
        console2.log("  SaucerSwapAdapter  :", address(saucerSwapAdapter));

        BonzoAdapter bonzoAdapter = new BonzoAdapter(deployer, cfg.bonzoLendingPool, cfg.bonzoDataProvider);
        deployments.push(Deployment({ name: "BonzoAdapter", addr: address(bonzoAdapter) }));
        console2.log("  BonzoAdapter       :", address(bonzoAdapter));

        // 5. Allowlist them. `enableAdapter` reads `protocolId()` as it goes, so a contract that
        //    does not implement the interface fails here rather than mid-action.
        router.enableAdapter(address(saucerSwapAdapter));
        router.enableAdapter(address(bonzoAdapter));

        _assertWiring(registry, router, saucerSwapAdapter, bonzoAdapter);

        console2.log("Deployed and wired. Next: AssociateTokens.s.sol, then register an agent.");
    }

    /// @dev Fails the run if anything is not connected as intended.
    function _assertWiring(
        AgentRegistry registry,
        ActionRouter router,
        SaucerSwapAdapter saucerSwapAdapter,
        BonzoAdapter bonzoAdapter
    ) private view {
        require(address(router.registry()) == address(registry), "router is bound to the wrong registry");
        require(registry.actionRouter() == address(router), "registry does not accept this router");
        require(router.isAdapterEnabled(address(saucerSwapAdapter)), "SaucerSwap adapter is not enabled");
        require(router.isAdapterEnabled(address(bonzoAdapter)), "Bonzo adapter is not enabled");
        require(registry.owner() == deployer, "registry owner is not the deployer");
        require(router.owner() == deployer, "router owner is not the deployer");
        require(saucerSwapAdapter.owner() == deployer, "SaucerSwap adapter owner is not the deployer");
        require(bonzoAdapter.owner() == deployer, "Bonzo adapter owner is not the deployer");
    }
}
