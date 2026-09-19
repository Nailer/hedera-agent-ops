// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ActionRouter } from "../contracts/ActionRouter.sol";
import { AgentRegistry } from "../contracts/AgentRegistry.sol";
import { IAgentAction } from "../contracts/interfaces/IAgentAction.sol";
import { MockERC20 } from "./harnesses/MockERC20.sol";
import { MockAdapter, ReentrantAdapter, NonConformingAdapter } from "./harnesses/MockAdapters.sol";

/**
 * @notice Tests for ActionRouter.
 *
 * The router moves other people's money, so most of this file is about what happens when something
 * in the path misbehaves: an adapter that is not allowlisted, one that lies about what it
 * delivered, one that under-delivers, one that reenters. A router that only works when every
 * adapter is honest is not a security boundary.
 */
contract ActionRouterTest is Test {
    ActionRouter internal router;
    AgentRegistry internal registry;
    MockAdapter internal adapter;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = makeAddr("owner");
    address internal controller = makeAddr("controller");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MAX_PER_ACTION = 1000e18;
    uint256 internal constant MAX_PER_EPOCH = 5000e18;
    uint64 internal constant EPOCH = 1 days;
    uint256 internal constant TREASURY_FUNDS = 10_000e18;

    uint256 internal agentId;

    function setUp() public {
        registry = new AgentRegistry(owner);
        router = new ActionRouter(owner, address(registry));

        vm.prank(owner);
        registry.setActionRouter(address(router));

        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");

        adapter = new MockAdapter(bytes32("mock-protocol"));
        vm.prank(owner);
        router.enableAdapter(address(adapter));

        vm.prank(controller);
        agentId = registry.registerAgent(operator, treasury, "ipfs://agent");

        vm.startPrank(controller);
        registry.setSpendPolicy(agentId, address(tokenIn), MAX_PER_ACTION, MAX_PER_EPOCH, EPOCH);
        registry.setSpendPolicy(agentId, address(tokenOut), MAX_PER_ACTION, MAX_PER_EPOCH, EPOCH);
        vm.stopPrank();

        tokenIn.mint(treasury, TREASURY_FUNDS);
        vm.prank(treasury);
        tokenIn.approve(address(router), type(uint256).max);

        // The adapter must hold output to deliver, the way a real pool holds liquidity.
        tokenOut.mint(address(adapter), TREASURY_FUNDS);
    }

    function _request(uint256 amountIn, uint256 minOut) internal view returns (IAgentAction.ActionRequest memory) {
        return IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Swap,
            assetIn: address(tokenIn),
            amountIn: amountIn,
            assetOut: address(tokenOut),
            minAmountOut: minOut,
            protocolData: ""
        });
    }

    // --- adapter allowlist ---

    function test_RevertWhen_AdapterNotEnabled() public {
        MockAdapter rogue = new MockAdapter(bytes32("rogue"));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ActionRouter.ActionRouter__AdapterNotEnabled.selector, address(rogue)));
        router.executeAction(agentId, address(rogue), _request(100e18, 0));
    }

    /// @dev The allowlist is what makes the treasury's approval to this router safe. Without it a
    ///      caller supplies their own adapter and the router pulls treasury funds into it.
    function test_RevertWhen_StrangerSuppliesOwnAdapter() public {
        MockAdapter rogue = new MockAdapter(bytes32("rogue"));
        tokenOut.mint(address(rogue), 1000e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ActionRouter.ActionRouter__AdapterNotEnabled.selector, address(rogue)));
        router.executeAction(agentId, address(rogue), _request(100e18, 0));

        assertEq(tokenIn.balanceOf(treasury), TREASURY_FUNDS, "treasury must be untouched");
    }

    function test_RevertWhen_NonOwnerEnablesAdapter() public {
        MockAdapter other = new MockAdapter(bytes32("other"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.enableAdapter(address(other));
    }

    /// @dev Fail at enable time, not mid-action with funds in flight.
    function test_RevertWhen_EnablingNonConformingAdapter() public {
        NonConformingAdapter bad = new NonConformingAdapter();
        vm.prank(owner);
        vm.expectRevert();
        router.enableAdapter(address(bad));
    }

    function test_RevertWhen_EnablingZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ActionRouter.ActionRouter__ZeroAddress.selector);
        router.enableAdapter(address(0));
    }

    function test_DisableAdapterTakesEffectImmediately() public {
        vm.prank(owner);
        router.disableAdapter(address(adapter));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ActionRouter.ActionRouter__AdapterNotEnabled.selector, address(adapter)));
        router.executeAction(agentId, address(adapter), _request(100e18, 0));
    }

    function test_RevertWhen_AdapterDoesNotSupportKind() public {
        adapter.setSupported(IAgentAction.ActionKind.Swap, false);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ActionRouter.ActionRouter__AdapterRejectsAction.selector, address(adapter), IAgentAction.ActionKind.Swap
            )
        );
        router.executeAction(agentId, address(adapter), _request(100e18, 0));
    }

    // --- input validation ---

    function test_RevertWhen_AmountInIsZero() public {
        vm.prank(operator);
        vm.expectRevert(ActionRouter.ActionRouter__ZeroAmount.selector);
        router.executeAction(agentId, address(adapter), _request(0, 0));
    }

    function test_RevertWhen_AssetIsZeroAddress() public {
        IAgentAction.ActionRequest memory request = _request(100e18, 0);
        request.assetOut = address(0);
        vm.prank(operator);
        vm.expectRevert(ActionRouter.ActionRouter__ZeroAddress.selector);
        router.executeAction(agentId, address(adapter), request);
    }

    // --- authorisation ---

    function test_RevertWhen_CallerIsNotTheOperator() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotOperator.selector, agentId, stranger));
        router.executeAction(agentId, address(adapter), _request(100e18, 0));
    }

    function test_RevertWhen_SpendExceedsPolicy() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentRegistry.AgentRegistry__ExceedsPerAction.selector, MAX_PER_ACTION + 1, MAX_PER_ACTION
            )
        );
        router.executeAction(agentId, address(adapter), _request(MAX_PER_ACTION + 1, 0));
    }

    function test_RevertWhen_AgentIsInactive() public {
        vm.prank(controller);
        registry.setActive(agentId, false);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__AgentInactive.selector, agentId));
        router.executeAction(agentId, address(adapter), _request(100e18, 0));
    }

    /// @dev Authorisation runs before any transfer, so a rejected action must leave balances intact.
    function test_RejectedActionMovesNoFunds() public {
        uint256 treasuryBefore = tokenIn.balanceOf(treasury);
        uint256 adapterBefore = tokenIn.balanceOf(address(adapter));

        vm.prank(stranger);
        vm.expectRevert();
        router.executeAction(agentId, address(adapter), _request(100e18, 0));

        assertEq(tokenIn.balanceOf(treasury), treasuryBefore);
        assertEq(tokenIn.balanceOf(address(adapter)), adapterBefore);
        assertEq(tokenIn.balanceOf(address(router)), 0);
    }

    // --- happy path ---

    function test_ExecuteMovesFundsAndDelivers() public {
        adapter.setOutputAmount(250e18);

        vm.prank(operator);
        uint256 amountOut = router.executeAction(agentId, address(adapter), _request(100e18, 0));

        assertEq(amountOut, 250e18);
        assertEq(tokenIn.balanceOf(treasury), TREASURY_FUNDS - 100e18, "input left the treasury");
        assertEq(tokenIn.balanceOf(address(adapter)), 100e18, "adapter received the input");
        assertEq(tokenOut.balanceOf(treasury), 250e18, "output reached the treasury");
    }

    /// @dev The router must never retain a balance once the call returns.
    function test_RouterRetainsNothing() public {
        adapter.setOutputAmount(250e18);
        adapter.setUnspentInput(30e18);

        vm.prank(operator);
        router.executeAction(agentId, address(adapter), _request(100e18, 0));

        assertEq(tokenIn.balanceOf(address(router)), 0);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    function test_UnspentInputIsReturnedToTreasury() public {
        adapter.setOutputAmount(200e18);
        adapter.setUnspentInput(40e18);

        vm.prank(operator);
        router.executeAction(agentId, address(adapter), _request(100e18, 0));

        // 100 left, 40 came back.
        assertEq(tokenIn.balanceOf(treasury), TREASURY_FUNDS - 60e18);
    }

    function test_SequenceIncrementsPerAgent() public {
        adapter.setOutputAmount(10e18);

        vm.startPrank(operator);
        router.executeAction(agentId, address(adapter), _request(100e18, 0));
        assertEq(router.actionCount(agentId), 1);
        router.executeAction(agentId, address(adapter), _request(100e18, 0));
        assertEq(router.actionCount(agentId), 2);
        vm.stopPrank();
    }

    function test_ExecuteRecordsSpendAgainstBudget() public {
        adapter.setOutputAmount(10e18);

        vm.prank(operator);
        router.executeAction(agentId, address(adapter), _request(100e18, 0));

        assertEq(registry.spentThisEpoch(agentId, address(tokenIn)), 100e18);
    }

    // --- measured, not reported ---

    /// @dev The central safety property. The adapter claims one figure and delivers another; the
    ///      receipt and the return value must both reflect what actually arrived.
    function test_MeasuresDeliveryRatherThanTrustingTheAdapter() public {
        adapter.setLie({ actualDelivered: 5e18, claimed: 9999e18 });

        vm.prank(operator);
        uint256 amountOut = router.executeAction(agentId, address(adapter), _request(100e18, 0));

        assertEq(amountOut, 5e18, "must report what was measured, not what was claimed");
        assertEq(tokenOut.balanceOf(treasury), 5e18);
    }

    /// @dev A lie must not be able to sneak past the slippage floor either.
    function test_RevertWhen_LyingAdapterUnderDeliversBelowMinimum() public {
        adapter.setLie({ actualDelivered: 5e18, claimed: 9999e18 });

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ActionRouter.ActionRouter__InsufficientOutput.selector, 5e18, 100e18));
        router.executeAction(agentId, address(adapter), _request(100e18, 100e18));
    }

    function test_RevertWhen_DeliveryIsBelowMinimum() public {
        adapter.setOutputAmount(50e18);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ActionRouter.ActionRouter__InsufficientOutput.selector, 50e18, 60e18));
        router.executeAction(agentId, address(adapter), _request(100e18, 60e18));
    }

    function test_ExactlyMinimumIsAccepted() public {
        adapter.setOutputAmount(60e18);

        vm.prank(operator);
        uint256 amountOut = router.executeAction(agentId, address(adapter), _request(100e18, 60e18));
        assertEq(amountOut, 60e18);
    }

    // --- same-asset accounting ---

    /// @dev When assetIn == assetOut the snapshot is taken after the input has left, so the delta
    ///      captures everything returned without double-counting an unspent-input sweep.
    function test_SameAssetInAndOutAccountsCorrectly() public {
        MockAdapter sameAssetAdapter = new MockAdapter(bytes32("same-asset"));
        vm.prank(owner);
        router.enableAdapter(address(sameAssetAdapter));
        tokenIn.mint(address(sameAssetAdapter), 1000e18);
        sameAssetAdapter.setOutputAmount(120e18);

        IAgentAction.ActionRequest memory request = IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Repay,
            assetIn: address(tokenIn),
            amountIn: 100e18,
            assetOut: address(tokenIn),
            minAmountOut: 0,
            protocolData: ""
        });

        vm.prank(operator);
        uint256 amountOut = router.executeAction(agentId, address(sameAssetAdapter), request);

        assertEq(amountOut, 120e18);
        assertEq(tokenIn.balanceOf(address(router)), 0, "router must retain nothing");
        assertEq(tokenIn.balanceOf(treasury), TREASURY_FUNDS - 100e18 + 120e18);
    }

    // --- reentrancy ---

    function test_ReentrantAdapterIsBlocked() public {
        ReentrantAdapter evil = new ReentrantAdapter(router, agentId);
        vm.prank(owner);
        router.enableAdapter(address(evil));
        tokenOut.mint(address(evil), 1000e18);

        vm.prank(operator);
        router.executeAction(agentId, address(evil), _request(100e18, 0));

        assertTrue(evil.didAttempt(), "adapter should have attempted reentry");
        assertTrue(evil.attemptReverted(), "reentry must have been rejected");

        // Assert *why* it failed. Without this the test would also pass if the nested call happened
        // to revert for an unrelated reason, and would stop proving the guard works.
        assertEq(
            bytes4(evil.attemptRevertData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "reentry must be rejected by the reentrancy guard specifically"
        );
    }

    // --- receipt ---

    function test_EmitsReceiptWithMeasuredAmount() public {
        adapter.setLie({ actualDelivered: 42e18, claimed: 1e30 });

        vm.recordLogs();
        vm.prank(operator);
        router.executeAction(agentId, address(adapter), _request(100e18, 0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "ActionExecuted(uint256,bytes32,uint8,address,address,uint256,address,uint256,bytes32,uint256)"
        );

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            found = true;

            assertEq(uint256(logs[i].topics[1]), agentId);
            assertEq(logs[i].topics[2], bytes32("mock-protocol"));
            assertEq(uint256(logs[i].topics[3]), uint256(uint8(IAgentAction.ActionKind.Swap)));

            (
                address loggedOperator,
                address assetIn,
                uint256 amountIn,
                address assetOut,
                uint256 amountOut,
                bytes32 protocolRef,
                uint256 sequence
            ) = abi.decode(logs[i].data, (address, address, uint256, address, uint256, bytes32, uint256));

            assertEq(loggedOperator, operator);
            assertEq(assetIn, address(tokenIn));
            assertEq(amountIn, 100e18);
            assertEq(assetOut, address(tokenOut));
            assertEq(amountOut, 42e18, "receipt must carry the measured amount");
            assertEq(protocolRef, bytes32("mock-pool"));
            assertEq(sequence, 1);
        }
        assertTrue(found, "no ActionExecuted receipt emitted");
    }
}
