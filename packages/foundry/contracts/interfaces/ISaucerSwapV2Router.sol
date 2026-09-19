// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice The slice of SaucerSwap's V2 SwapRouter this template uses.
 *
 * @dev Taken from SaucerSwap's published `ISwapRouter.sol`, not from Uniswap V3. The shapes differ
 *      in a way that matters: SaucerSwap carries `deadline` **inside** `ExactInputParams`, whereas
 *      Uniswap V3 dropped it from the struct and applies it via a `multicall` deadline modifier.
 *      Copying the Uniswap ABI here would encode the wrong calldata and fail at the router with no
 *      useful message.
 *
 *      Path encoding is `[token(20) | fee(3) | token(20) | fee(3) | ...]`, fee in hundredths of a
 *      bip — `0x0001F4` is 500, i.e. 0.05%.
 */
interface ISaucerSwapV2Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Read-only quoting. `quoteExactInput` is `nonpayable`, so it must be simulated rather
///         than called as a `view` — calling it as a view reverts.
interface ISaucerSwapV2Quoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}
