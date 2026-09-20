// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SaucerSwapAdapter } from "../contracts/adapters/SaucerSwapAdapter.sol";
import { IAgentAction } from "../contracts/interfaces/IAgentAction.sol";
import { HtsAssociatable } from "../contracts/HtsAssociatable.sol";
import { MockERC20 } from "./harnesses/MockERC20.sol";
import { MockSwapRouter } from "./harnesses/MockSwapRouter.sol";

/**
 * @notice Tests for SaucerSwapAdapter.
 *
 * Weighted heavily toward path validation, because that is the check standing between the
 * registry's spend policy and an operator who controls `protocolData`. Everything else here is
 * encoding: proving the adapter hands SaucerSwap exactly the parameters it was given.
 */
contract SaucerSwapAdapterTest is Test {
    SaucerSwapAdapter internal adapter;
    MockSwapRouter internal swapRouter;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal owner = makeAddr("owner");
    address internal actionRouter = makeAddr("actionRouter");
    address internal stranger = makeAddr("stranger");

    uint24 internal constant FEE_LOW = 500; // 0x0001F4, 0.05%
    uint24 internal constant FEE_MED = 3000;
    uint256 internal constant AMOUNT_IN = 100e18;

    function setUp() public {
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");

        swapRouter = new MockSwapRouter(address(tokenB));
        adapter = new SaucerSwapAdapter(owner, address(swapRouter));

        tokenB.mint(address(swapRouter), 1_000_000e18);
        // The ActionRouter transfers input to the adapter before calling execute.
        tokenA.mint(address(adapter), 1_000_000e18);
    }

    /// @dev `[token | fee | token]`, SaucerSwap's encoding.
    function _path(address t0, uint24 fee, address t1) internal pure returns (bytes memory) {
        return abi.encodePacked(t0, fee, t1);
    }

    function _path2(address t0, uint24 f0, address t1, uint24 f1, address t2) internal pure returns (bytes memory) {
        return abi.encodePacked(t0, f0, t1, f1, t2);
    }

    function _request(bytes memory path, uint256 deadline, uint256 minOut)
        internal
        view
        returns (IAgentAction.ActionRequest memory)
    {
        return IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Swap,
            assetIn: address(tokenA),
            amountIn: AMOUNT_IN,
            assetOut: address(tokenB),
            minAmountOut: minOut,
            protocolData: abi.encode(path, deadline)
        });
    }

    // --- metadata ---

    function test_ProtocolIdIsStable() public view {
        assertEq(adapter.protocolId(), bytes32("saucerswap-v2"));
    }

    function test_SupportsOnlySwap() public view {
        assertTrue(adapter.supportsAction(IAgentAction.ActionKind.Swap));
        assertFalse(adapter.supportsAction(IAgentAction.ActionKind.Supply));
        assertFalse(adapter.supportsAction(IAgentAction.ActionKind.Withdraw));
        assertFalse(adapter.supportsAction(IAgentAction.ActionKind.Borrow));
        assertFalse(adapter.supportsAction(IAgentAction.ActionKind.Repay));
    }

    function test_RevertWhen_KindIsNotSwap() public {
        IAgentAction.ActionRequest memory request =
            _request(_path(address(tokenA), FEE_LOW, address(tokenB)), block.timestamp + 60, 0);
        request.kind = IAgentAction.ActionKind.Supply;

        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentAction.IAgentAction__UnsupportedAction.selector, IAgentAction.ActionKind.Supply
            )
        );
        adapter.execute(request, actionRouter);
    }

    function test_RevertWhen_ConstructedWithZeroRouter() public {
        vm.expectRevert(SaucerSwapAdapter.SaucerSwapAdapter__ZeroAddress.selector);
        new SaucerSwapAdapter(owner, address(0));
    }

    // --- path validation: the budget-integrity check ---

    /**
     * @dev The registry charges the agent's budget against `request.assetIn`, but the path lives in
     *      opaque protocolData. If a path starting at a different token were accepted, the operator
     *      would spend an asset the spend policy never authorised. This is the test that matters.
     */
    function test_RevertWhen_PathInputDoesNotMatchDeclaredAssetIn() public {
        bytes memory sneaky = _path(address(tokenC), FEE_LOW, address(tokenB));
        IAgentAction.ActionRequest memory request = _request(sneaky, block.timestamp + 60, 0);

        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SaucerSwapAdapter.SaucerSwapAdapter__PathInputMismatch.selector, address(tokenC), address(tokenA)
            )
        );
        adapter.execute(request, actionRouter);
    }

    /// @dev Likewise the far end: delivering a different token than declared would make the
    ///      router's measured delta read zero and the receipt describe something that never happened.
    function test_RevertWhen_PathOutputDoesNotMatchDeclaredAssetOut() public {
        bytes memory sneaky = _path(address(tokenA), FEE_LOW, address(tokenC));
        IAgentAction.ActionRequest memory request = _request(sneaky, block.timestamp + 60, 0);

        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SaucerSwapAdapter.SaucerSwapAdapter__PathOutputMismatch.selector, address(tokenC), address(tokenB)
            )
        );
        adapter.execute(request, actionRouter);
    }

    function test_RevertWhen_PathIsTooShort() public {
        bytes memory short = abi.encodePacked(address(tokenA), FEE_LOW);
        IAgentAction.ActionRequest memory request = _request(short, block.timestamp + 60, 0);

        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(SaucerSwapAdapter.SaucerSwapAdapter__MalformedPath.selector, 23));
        adapter.execute(request, actionRouter);
    }

    function test_RevertWhen_PathLengthIsNotAWholeNumberOfHops() public {
        bytes memory ragged = abi.encodePacked(_path(address(tokenA), FEE_LOW, address(tokenB)), uint8(7));
        IAgentAction.ActionRequest memory request = _request(ragged, block.timestamp + 60, 0);

        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(SaucerSwapAdapter.SaucerSwapAdapter__MalformedPath.selector, 44));
        adapter.execute(request, actionRouter);
    }

    function test_RevertWhen_PathIsEmpty() public {
        IAgentAction.ActionRequest memory request = _request("", block.timestamp + 60, 0);

        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(SaucerSwapAdapter.SaucerSwapAdapter__MalformedPath.selector, 0));
        adapter.execute(request, actionRouter);
    }

    /// @dev Multi-hop must validate the ends, not the intermediate token.
    function test_MultiHopPathValidatesOnlyItsEndpoints() public {
        swapRouter.setAmountToReturn(250e18);
        bytes memory multi = _path2(address(tokenA), FEE_LOW, address(tokenC), FEE_MED, address(tokenB));

        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result =
            adapter.execute(_request(multi, block.timestamp + 60, 0), actionRouter);

        assertEq(result.amountOut, 250e18);
        assertEq(swapRouter.lastPath(), multi, "path must be forwarded unmodified");
    }

    // --- encoding ---

    function test_ForwardsParametersVerbatim() public {
        swapRouter.setAmountToReturn(321e18);
        uint256 deadline = block.timestamp + 1234;
        bytes memory path = _path(address(tokenA), FEE_LOW, address(tokenB));

        vm.prank(actionRouter);
        adapter.execute(_request(path, deadline, 77e18), actionRouter);

        assertEq(swapRouter.lastPath(), path);
        assertEq(swapRouter.lastDeadline(), deadline, "caller's deadline must be used, not a derived one");
        assertEq(swapRouter.lastAmountIn(), AMOUNT_IN);
        assertEq(swapRouter.lastAmountOutMinimum(), 77e18);
    }

    /// @dev Output goes to the caller, per the IAgentAction contract, with no intermediate hop.
    function test_RecipientIsTheCallingRouter() public {
        swapRouter.setAmountToReturn(150e18);

        vm.prank(actionRouter);
        adapter.execute(
            _request(_path(address(tokenA), FEE_LOW, address(tokenB)), block.timestamp + 60, 0), actionRouter
        );

        assertEq(swapRouter.lastRecipient(), actionRouter);
        assertEq(tokenB.balanceOf(actionRouter), 150e18, "caller receives the output directly");
    }

    /// @dev A deadline in the past is the caller's to supply and SaucerSwap's to reject; the point
    ///      is that the adapter does not quietly replace it with one that always passes.
    function test_PastDeadlineIsForwardedNotRewritten() public {
        swapRouter.setAmountToReturn(10e18);
        vm.warp(1_000_000);
        uint256 staleDeadline = block.timestamp - 1;

        vm.prank(actionRouter);
        adapter.execute(_request(_path(address(tokenA), FEE_LOW, address(tokenB)), staleDeadline, 0), actionRouter);

        assertEq(swapRouter.lastDeadline(), staleDeadline);
    }

    // --- allowance hygiene ---

    function test_LeavesNoStandingAllowance() public {
        swapRouter.setAmountToReturn(150e18);

        vm.prank(actionRouter);
        adapter.execute(
            _request(_path(address(tokenA), FEE_LOW, address(tokenB)), block.timestamp + 60, 0), actionRouter
        );

        assertEq(tokenA.allowance(address(adapter), address(swapRouter)), 0, "residual approval must be cleared");
    }

    function test_AllowanceIsGrantedForTheSwap() public {
        swapRouter.setAmountToReturn(150e18);
        uint256 routerBalanceBefore = tokenA.balanceOf(address(swapRouter));

        vm.prank(actionRouter);
        adapter.execute(
            _request(_path(address(tokenA), FEE_LOW, address(tokenB)), block.timestamp + 60, 0), actionRouter
        );

        // The mock pulls via transferFrom, so a missing allowance would have reverted.
        assertEq(tokenA.balanceOf(address(swapRouter)) - routerBalanceBefore, AMOUNT_IN);
    }

    // --- result ---

    function test_ProtocolRefIsThePathHash() public {
        swapRouter.setAmountToReturn(150e18);
        bytes memory path = _path(address(tokenA), FEE_LOW, address(tokenB));

        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result = adapter.execute(_request(path, block.timestamp + 60, 0), actionRouter);

        assertEq(result.protocolRef, keccak256(path), "receipt must identify the route taken");
        assertEq(result.assetOut, address(tokenB));
    }

    function test_RevertWhen_UnderlyingSwapReverts() public {
        swapRouter.setShouldRevert(true);

        vm.prank(actionRouter);
        vm.expectRevert(bytes("Too little received"));
        adapter.execute(
            _request(_path(address(tokenA), FEE_LOW, address(tokenB)), block.timestamp + 60, 0), actionRouter
        );
    }

    // --- association ---

    function test_RevertWhen_NonOwnerAssociates() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.associate(address(tokenA));
    }

    function test_RevertWhen_AssociatingZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(HtsAssociatable.HtsAssociatable__ZeroAddress.selector);
        adapter.associate(address(0));
    }

    // --- fuzz ---

    /// @dev Only a path whose endpoints match the request may be accepted, for any token triple.
    function testFuzz_OnlyMatchingEndpointsAreAccepted(address pathIn, address pathOut) public {
        vm.assume(pathIn != address(0) && pathOut != address(0));
        swapRouter.setAmountToReturn(1e18);

        bytes memory path = _path(pathIn, FEE_LOW, pathOut);
        IAgentAction.ActionRequest memory request = _request(path, block.timestamp + 60, 0);

        bool inMatches = pathIn == address(tokenA);
        bool outMatches = pathOut == address(tokenB);

        vm.prank(actionRouter);
        if (inMatches && outMatches) {
            adapter.execute(request, actionRouter);
        } else {
            vm.expectRevert();
            adapter.execute(request, actionRouter);
        }
    }

    /// @dev Any length that is not `20 + n*23` for n >= 1 must be rejected as malformed.
    function testFuzz_MalformedPathLengthsAreRejected(uint8 rawLength) public {
        uint256 length = bound(rawLength, 0, 200);
        vm.assume(length < 43 || (length - 20) % 23 != 0);

        bytes memory path = new bytes(length);
        IAgentAction.ActionRequest memory request = _request(path, block.timestamp + 60, 0);

        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(SaucerSwapAdapter.SaucerSwapAdapter__MalformedPath.selector, length));
        adapter.execute(request, actionRouter);
    }
}
