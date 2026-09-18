// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAgentAction
 * @notice The only surface the router knows about. Every protocol this template supports is reached
 *         through an adapter implementing this interface.
 *
 * @dev Design notes, because the shape here is load-bearing:
 *
 * **One `execute` rather than one method per operation.** Separate `swap` / `supply` / `borrow`
 * methods would type-check better, but every adapter would then have to implement operations it
 * cannot perform, and adding a new operation would mean editing the router and all adapters. A
 * tagged request keeps the router closed to modification: a new protocol is a new file.
 *
 * **Adapters declare their own capabilities.** `supportsAction` lets the router reject an
 * unsupported pairing with a clear error instead of forwarding a call that reverts somewhere deep
 * inside a third-party protocol with no useful message.
 *
 * **Adapters do not emit receipts.** They return an `ActionResult` and the router emits. If each
 * adapter emitted its own event, an adapter could silently skip it, and the audit trail would only
 * be as trustworthy as the least careful adapter. Keeping the emit in one place the adapter cannot
 * reach is what makes "every action is recorded" structural rather than aspirational.
 *
 * **Adapters are not trusted with custody beyond one call.** The router moves exactly the input
 * amount to the adapter immediately before `execute` and expects the output back within the same
 * call. An adapter is a translator, not a vault.
 */
interface IAgentAction {
    /**
     * @notice The operations an agent can perform.
     * @dev Append only. These values are written into receipts and, from there, into the HCS audit
     *      topic — renumbering them would silently rewrite the meaning of historical records.
     */
    enum ActionKind {
        Swap,
        Supply,
        Withdraw,
        Borrow,
        Repay
    }

    /**
     * @param kind Which operation to perform.
     * @param assetIn Token the agent is spending. For operations that spend nothing (`Withdraw`,
     *        `Borrow`) this is the reserve being drawn from.
     * @param amountIn Amount of `assetIn`, in that token's smallest unit.
     * @param assetOut Token the agent expects back. Equal to `assetIn` for `Supply` / `Withdraw`,
     *        where the position is denominated in the same asset.
     * @param minAmountOut Slippage floor. The adapter MUST revert rather than return less. Passing
     *        zero disables the check and is only appropriate for operations with no price exposure.
     * @param protocolData Adapter-specific encoding — a SaucerSwap fee tier and path, a Bonzo
     *        interest-rate mode. Opaque to the router by design: the router cannot acquire
     *        protocol-specific knowledge without becoming something every new protocol must edit.
     */
    struct ActionRequest {
        ActionKind kind;
        address assetIn;
        uint256 amountIn;
        address assetOut;
        uint256 minAmountOut;
        bytes protocolData;
    }

    /**
     * @param assetOut Token actually delivered. Normally equals `request.assetOut`; returned so the
     *        router records what happened rather than what was asked for.
     * @param amountOut Amount actually delivered, in that token's smallest unit.
     * @param protocolRef The specific venue touched — a pool, a reserve. Recorded in the receipt so
     *        an auditor can reconstruct the route without replaying the transaction.
     */
    struct ActionResult {
        address assetOut;
        uint256 amountOut;
        bytes32 protocolRef;
    }

    /// @notice Thrown when the router asks for an operation this adapter does not implement.
    error IAgentAction__UnsupportedAction(ActionKind kind);

    /// @notice Thrown when the delivered amount is below `request.minAmountOut`.
    error IAgentAction__InsufficientOutput(uint256 received, uint256 minimum);

    /**
     * @notice Perform one action against the underlying protocol.
     * @dev The router transfers `request.amountIn` of `request.assetIn` to the adapter before this
     *      call. The adapter MUST return any output to `msg.sender` (the router) before returning,
     *      and MUST NOT retain a balance between calls.
     * @param request What to do.
     * @param onBehalfOf The agent's treasury. Passed through for protocols that credit positions to
     *        a named account rather than to the caller; adapters that do not need it ignore it.
     * @return result What actually happened.
     */
    function execute(ActionRequest calldata request, address onBehalfOf)
        external
        payable
        returns (ActionResult memory result);

    /// @notice Whether this adapter implements `kind`.
    function supportsAction(ActionKind kind) external view returns (bool);

    /**
     * @notice Stable identifier for the protocol behind this adapter, e.g. `bytes32("saucerswap-v2")`.
     * @dev Written into every receipt. Must not change for a deployed adapter — it is the join key
     *      between an on-chain receipt and the off-chain audit record.
     */
    function protocolId() external view returns (bytes32);
}
