// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISaucerSwapV2Router } from "../../contracts/interfaces/ISaucerSwapV2Router.sol";

/**
 * @notice Stand-in for SaucerSwap's V2 SwapRouter.
 *
 * @dev Pulls the input via `transferFrom` and pays out a configured amount, so the adapter's
 *      allowance handling is genuinely exercised rather than assumed. Records the parameters it
 *      received so tests can assert what the adapter actually encoded.
 */
contract MockSwapRouter is ISaucerSwapV2Router {
    uint256 public amountToReturn;
    bool public shouldRevert;

    bytes public lastPath;
    address public lastRecipient;
    uint256 public lastDeadline;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;

    address private immutable _outputToken;

    constructor(address outputToken) {
        _outputToken = outputToken;
    }

    function setAmountToReturn(uint256 amount) external {
        amountToReturn = amount;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        if (shouldRevert) revert("Too little received");

        lastPath = params.path;
        lastRecipient = params.recipient;
        lastDeadline = params.deadline;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;

        // Exercise the allowance the adapter granted.
        address tokenIn = _firstToken(params.path);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        IERC20(_outputToken).transfer(params.recipient, amountToReturn);
        return amountToReturn;
    }

    function _firstToken(bytes memory path) private pure returns (address token) {
        assembly {
            token := shr(96, mload(add(path, 0x20)))
        }
    }
}
