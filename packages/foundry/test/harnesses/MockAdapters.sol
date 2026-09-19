// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAgentAction } from "../../contracts/interfaces/IAgentAction.sol";
import { ActionRouter } from "../../contracts/ActionRouter.sol";

/**
 * @notice A well-behaved adapter whose delivery is configurable.
 * @dev Must be pre-funded with the output token. Delivers `outputAmount` to `msg.sender` (the
 *      router) and optionally returns `unspentInput` of the input token, standing in for a protocol
 *      that consumed less than it was given.
 */
contract MockAdapter is IAgentAction {
    bytes32 private immutable _protocolId;

    uint256 public outputAmount;
    uint256 public unspentInput;
    uint256 public claimedAmountOut;
    bytes32 public protocolRefValue = bytes32("mock-pool");

    mapping(ActionKind => bool) private _supported;

    constructor(bytes32 protocolId_) {
        _protocolId = protocolId_;
        _supported[ActionKind.Swap] = true;
        _supported[ActionKind.Supply] = true;
        _supported[ActionKind.Withdraw] = true;
        _supported[ActionKind.Borrow] = true;
        _supported[ActionKind.Repay] = true;
    }

    function setOutputAmount(uint256 amount) external {
        outputAmount = amount;
        claimedAmountOut = amount;
    }

    /// @notice Deliver one amount while reporting another — a buggy or hostile adapter.
    function setLie(uint256 actualDelivered, uint256 claimed) external {
        outputAmount = actualDelivered;
        claimedAmountOut = claimed;
    }

    function setUnspentInput(uint256 amount) external {
        unspentInput = amount;
    }

    function setSupported(ActionKind kind, bool supported) external {
        _supported[kind] = supported;
    }

    function execute(ActionRequest calldata request, address) external payable returns (ActionResult memory) {
        if (unspentInput > 0) {
            IERC20(request.assetIn).transfer(msg.sender, unspentInput);
        }
        if (outputAmount > 0) {
            IERC20(request.assetOut).transfer(msg.sender, outputAmount);
        }
        return ActionResult({ assetOut: request.assetOut, amountOut: claimedAmountOut, protocolRef: protocolRefValue });
    }

    function supportsAction(ActionKind kind) external view returns (bool) {
        return _supported[kind];
    }

    function protocolId() external view returns (bytes32) {
        return _protocolId;
    }
}

/// @notice Adapter that calls back into the router mid-execute, to prove the guard holds.
contract ReentrantAdapter is IAgentAction {
    ActionRouter public immutable router;
    uint256 public immutable agentId;
    bool public didAttempt;
    bool public attemptReverted;

    /// @notice Revert data from the reentry attempt, so a test can assert *why* it failed rather
    ///         than merely that it did. A swallowed reason would let this pass for the wrong cause.
    bytes public attemptRevertData;

    constructor(ActionRouter router_, uint256 agentId_) {
        router = router_;
        agentId = agentId_;
    }

    function execute(ActionRequest calldata request, address) external payable returns (ActionResult memory) {
        didAttempt = true;
        try router.executeAction(agentId, address(this), request) {
            attemptReverted = false;
        } catch (bytes memory reason) {
            attemptReverted = true;
            attemptRevertData = reason;
        }
        return ActionResult({ assetOut: request.assetOut, amountOut: 0, protocolRef: bytes32(0) });
    }

    function supportsAction(ActionKind) external pure returns (bool) {
        return true;
    }

    function protocolId() external pure returns (bytes32) {
        return bytes32("reentrant");
    }
}

/// @notice Has no `protocolId()`, so enabling it must fail rather than succeeding silently.
contract NonConformingAdapter {
    function hello() external pure returns (uint256) {
        return 1;
    }
}
