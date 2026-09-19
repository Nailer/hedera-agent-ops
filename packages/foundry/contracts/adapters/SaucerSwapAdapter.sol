// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAgentAction } from "../interfaces/IAgentAction.sol";
import { ISaucerSwapV2Router } from "../interfaces/ISaucerSwapV2Router.sol";
import { IHederaTokenService } from "../interfaces/IHederaTokenService.sol";

/**
 * @title SaucerSwapAdapter
 * @notice Translates an `IAgentAction` swap into a SaucerSwap V2 `exactInput` call.
 *
 * @dev **`protocolData` is `abi.encode(bytes path, uint256 deadline)`.**
 *
 * The path is SaucerSwap's own encoding, `[token(20) | fee(3) | token(20) | ...]`, with the fee in
 * hundredths of a bip. The deadline is supplied by the caller rather than derived here: an adapter
 * that computed `block.timestamp + n` would make the deadline unfalsifiable, since it would be
 * satisfied in whatever block the transaction eventually landed in. A deadline the caller cannot
 * set is not a deadline.
 *
 * **The path is validated against the request.** This is the important part, and it is not
 * obvious. The registry charges an agent's budget against `request.assetIn`, but the path lives
 * inside opaque `protocolData` that neither the registry nor the router inspects. Without a check
 * here, an operator could declare `assetIn` as a token with a generous budget while encoding a path
 * that actually spends a different one — and the on-chain spend limit would be enforcing nothing.
 * So the first token in the path must equal `request.assetIn` and the last must equal
 * `request.assetOut`.
 *
 * **Delivery goes straight to the router.** `recipient` is `msg.sender`, satisfying the
 * `IAgentAction` requirement that output is returned to the caller without an extra hop. It also
 * means the ActionRouter, not this adapter, is the account that must be associated with the output
 * token.
 *
 * **Association.** A Hedera account cannot hold an HTS token until associated, contracts included.
 * `associate` is exposed for the owner to prepare this adapter for tokens it will handle. The
 * router and the agent treasury need the same treatment for their own sides of the flow.
 */
contract SaucerSwapAdapter is IAgentAction, Ownable {
    using SafeERC20 for IERC20;

    error SaucerSwapAdapter__ZeroAddress();
    error SaucerSwapAdapter__MalformedPath(uint256 length);
    error SaucerSwapAdapter__PathInputMismatch(address pathToken, address requestToken);
    error SaucerSwapAdapter__PathOutputMismatch(address pathToken, address requestToken);
    error SaucerSwapAdapter__AssociationFailed(address token, int64 responseCode);

    event TokenAssociated(address indexed token);

    /// @dev HTS system contract. See AGENTS.md for why this is absent under a plain EVM fork.
    address private constant HTS = 0x0000000000000000000000000000000000000167;

    /// @dev HTS success. 194 is TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT, which is benign here.
    int64 private constant HTS_SUCCESS = 22;
    int64 private constant HTS_ALREADY_ASSOCIATED = 194;

    uint256 private constant ADDRESS_BYTES = 20;
    uint256 private constant FEE_BYTES = 3;
    /// @dev A single-hop path is `token | fee | token`.
    uint256 private constant MIN_PATH_BYTES = ADDRESS_BYTES + FEE_BYTES + ADDRESS_BYTES;
    uint256 private constant HOP_BYTES = FEE_BYTES + ADDRESS_BYTES;

    ISaucerSwapV2Router public immutable swapRouter;

    constructor(address initialOwner, address swapRouterAddress) Ownable(initialOwner) {
        if (swapRouterAddress == address(0)) revert SaucerSwapAdapter__ZeroAddress();
        swapRouter = ISaucerSwapV2Router(swapRouterAddress);
    }

    /// @inheritdoc IAgentAction
    function protocolId() external pure returns (bytes32) {
        return bytes32("saucerswap-v2");
    }

    /// @inheritdoc IAgentAction
    function supportsAction(ActionKind kind) external pure returns (bool) {
        return kind == ActionKind.Swap;
    }

    /**
     * @notice Associate this adapter with an HTS token so it can hold and move it.
     * @dev Idempotent: an already-associated token returns 194 and is treated as success, so a
     *      redeploy or a repeated setup script does not fail.
     */
    function associate(address token) external onlyOwner {
        if (token == address(0)) revert SaucerSwapAdapter__ZeroAddress();
        int64 responseCode = IHederaTokenService(HTS).associateToken(address(this), token);
        if (responseCode != HTS_SUCCESS && responseCode != HTS_ALREADY_ASSOCIATED) {
            revert SaucerSwapAdapter__AssociationFailed(token, responseCode);
        }
        emit TokenAssociated(token);
    }

    /// @inheritdoc IAgentAction
    function execute(ActionRequest calldata request, address) external payable returns (ActionResult memory) {
        if (request.kind != ActionKind.Swap) revert IAgentAction__UnsupportedAction(request.kind);

        (bytes memory path, uint256 deadline) = abi.decode(request.protocolData, (bytes, uint256));
        _validatePath(path, request.assetIn, request.assetOut);

        // The router requires an allowance for any non-HBAR input, enforced below the EVM.
        // forceApprove because HTS tokens reached through the ERC20 facade do not reliably accept a
        // non-zero-to-non-zero approve.
        IERC20(request.assetIn).forceApprove(address(swapRouter), request.amountIn);

        uint256 amountOut = swapRouter.exactInput(
            ISaucerSwapV2Router.ExactInputParams({
                path: path,
                // Straight to the ActionRouter: it is the account that measures delivery, and this
                // avoids a second transfer that would need its own association.
                recipient: msg.sender,
                deadline: deadline,
                amountIn: request.amountIn,
                // The router re-checks this against the measured delta. Passing it here as well
                // means the swap reverts at SaucerSwap before funds move, rather than unwinding.
                amountOutMinimum: request.minAmountOut
            })
        );

        // Leave no standing allowance behind. A residual approval on a shared adapter is exactly
        // the kind of thing that turns one future bug into a drained treasury.
        IERC20(request.assetIn).forceApprove(address(swapRouter), 0);

        return ActionResult({
            assetOut: request.assetOut,
            amountOut: amountOut,
            // The route taken, so an auditor can identify the venue from the receipt alone.
            protocolRef: keccak256(path)
        });
    }

    /**
     * @dev Rejects a path that is structurally malformed or that disagrees with the request.
     *      Length must be `20 + n*(3 + 20)` for at least one hop.
     */
    function _validatePath(bytes memory path, address assetIn, address assetOut) private pure {
        uint256 length = path.length;
        if (length < MIN_PATH_BYTES || (length - ADDRESS_BYTES) % HOP_BYTES != 0) {
            revert SaucerSwapAdapter__MalformedPath(length);
        }

        address first = _tokenAt(path, 0);
        if (first != assetIn) revert SaucerSwapAdapter__PathInputMismatch(first, assetIn);

        address last = _tokenAt(path, length - ADDRESS_BYTES);
        if (last != assetOut) revert SaucerSwapAdapter__PathOutputMismatch(last, assetOut);
    }

    /// @dev Reads the 20-byte address at `offset` within `path`.
    function _tokenAt(bytes memory path, uint256 offset) private pure returns (address token) {
        assembly {
            token := shr(96, mload(add(add(path, 0x20), offset)))
        }
    }
}
