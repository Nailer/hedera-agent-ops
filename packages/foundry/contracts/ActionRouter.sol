// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAgentAction } from "./interfaces/IAgentAction.sol";
import { AgentRegistry } from "./AgentRegistry.sol";

/**
 * @title ActionRouter
 * @notice The boundary an agent's action crosses. Checks the agent is allowed to act, moves funds
 *         for exactly one call, verifies what came back, and emits the receipt the audit trail is
 *         built from.
 *
 * @dev **Custody lasts one call.** The treasury approves this router and keeps custody at rest.
 * The router pulls the input, forwards it to the adapter, takes delivery, and returns everything to
 * the treasury within a single transaction. A router that held agent funds between actions would be
 * a honeypot; a design where the treasury approved adapters directly would make every future
 * adapter a standing trust decision.
 *
 * **Authorisation precedes movement.** `authorizeSpend` is called before any token moves. Checking
 * the budget after the swap would mean discovering the action was disallowed having already spent
 * the money.
 *
 * **Delivery is measured, never reported.** The adapter returns an `ActionResult` with its own
 * `amountOut`, and this contract ignores that figure for accounting, using the observed balance
 * delta instead. An adapter is semi-trusted: it may be buggy or hostile. Measuring means a lying
 * adapter cannot corrupt the receipt, so the audit trail stays honest even when an adapter is not.
 *
 * **Only allowlisted adapters.** Without this, any caller could pass an adapter they control and
 * have the router pull a treasury's approved balance straight into it. The allowlist is what makes
 * the approval to this router safe to grant.
 *
 * Native HBAR is not handled in this version. Every flow here is token-denominated; wrapping is the
 * adapter's business via WHBAR. `executeAction` is deliberately non-payable so there is no
 * half-built native path to mistake for a working one.
 */
contract ActionRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ActionRouter__ZeroAddress();
    error ActionRouter__ZeroAmount();
    error ActionRouter__AdapterNotEnabled(address adapter);
    error ActionRouter__AdapterRejectsAction(address adapter, IAgentAction.ActionKind kind);
    error ActionRouter__InsufficientOutput(uint256 received, uint256 minimum);
    error ActionRouter__SameAssetRequiresNoSweep();

    /**
     * @notice One agent action, as recorded. This event is the audit trail's source record; the HCS
     *         topic mirrors it off-chain.
     * @param sequence Per-agent counter, starting at 1. Gives the audit trail a total order per
     *        agent without relying on block or log ordering.
     * @param amountOut The *measured* delivery, not the adapter's claim.
     */
    event ActionExecuted(
        uint256 indexed agentId,
        bytes32 indexed protocolId,
        IAgentAction.ActionKind indexed kind,
        address operator,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        bytes32 protocolRef,
        uint256 sequence
    );

    event AdapterEnabled(address indexed adapter, bytes32 indexed protocolId);
    event AdapterDisabled(address indexed adapter);

    AgentRegistry public immutable registry;

    mapping(address adapter => bool enabled) public isAdapterEnabled;
    mapping(uint256 agentId => uint256 count) public actionCount;

    constructor(address initialOwner, address registryAddress) Ownable(initialOwner) {
        if (registryAddress == address(0)) revert ActionRouter__ZeroAddress();
        registry = AgentRegistry(registryAddress);
    }

    /**
     * @notice Permit an adapter to be used.
     * @dev Reads `protocolId()` at enable time so a non-conforming address fails here rather than
     *      mid-action with a treasury balance already in flight.
     */
    function enableAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ActionRouter__ZeroAddress();
        bytes32 protocolId = IAgentAction(adapter).protocolId();
        isAdapterEnabled[adapter] = true;
        emit AdapterEnabled(adapter, protocolId);
    }

    /// @notice Revoke an adapter. Takes effect immediately for every agent.
    function disableAdapter(address adapter) external onlyOwner {
        isAdapterEnabled[adapter] = false;
        emit AdapterDisabled(adapter);
    }

    /**
     * @notice Execute one action on behalf of an agent. Caller must be the agent's operator.
     * @dev Ordering is the security property here; see the contract docs. The treasury must have
     *      approved this router for at least `request.amountIn` of `request.assetIn`.
     * @return amountOut The measured amount delivered to the treasury.
     */
    function executeAction(uint256 agentId, address adapter, IAgentAction.ActionRequest calldata request)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!isAdapterEnabled[adapter]) revert ActionRouter__AdapterNotEnabled(adapter);
        if (request.amountIn == 0) revert ActionRouter__ZeroAmount();
        if (request.assetIn == address(0) || request.assetOut == address(0)) revert ActionRouter__ZeroAddress();
        if (!IAgentAction(adapter).supportsAction(request.kind)) {
            revert ActionRouter__AdapterRejectsAction(adapter, request.kind);
        }

        // Authorise before anything moves. A budget check after the fact is not a budget.
        registry.authorizeSpend(agentId, msg.sender, request.assetIn, request.amountIn);

        address treasury = registry.agentOf(agentId).treasury;

        IERC20(request.assetIn).safeTransferFrom(treasury, address(this), request.amountIn);
        IERC20(request.assetIn).safeTransfer(adapter, request.amountIn);

        // Snapshot AFTER the input has left. When assetIn == assetOut the router now holds none of
        // that token, so the delta below captures everything returned, unspent input included.
        uint256 outBefore = IERC20(request.assetOut).balanceOf(address(this));

        IAgentAction.ActionResult memory result = IAgentAction(adapter).execute(request, treasury);

        // Measured, not reported. `result.amountOut` is the adapter's claim and is not trusted for
        // accounting; it is carried only so `protocolRef` can name the venue in the receipt.
        amountOut = IERC20(request.assetOut).balanceOf(address(this)) - outBefore;

        if (amountOut < request.minAmountOut) {
            revert ActionRouter__InsufficientOutput(amountOut, request.minAmountOut);
        }

        // Return any input the adapter did not consume. Skipped when the assets are the same,
        // because the delta above already accounts for it and sweeping would double-count.
        if (request.assetIn != request.assetOut) {
            uint256 unspent = IERC20(request.assetIn).balanceOf(address(this));
            if (unspent > 0) IERC20(request.assetIn).safeTransfer(treasury, unspent);
        }

        if (amountOut > 0) IERC20(request.assetOut).safeTransfer(treasury, amountOut);

        uint256 sequence = ++actionCount[agentId];

        emit ActionExecuted(
            agentId,
            IAgentAction(adapter).protocolId(),
            request.kind,
            msg.sender,
            request.assetIn,
            request.amountIn,
            request.assetOut,
            amountOut,
            result.protocolRef,
            sequence
        );
    }
}
