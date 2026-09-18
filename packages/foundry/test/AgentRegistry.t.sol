// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AgentRegistry } from "../contracts/AgentRegistry.sol";

/**
 * @notice Tests for AgentRegistry.
 *
 * The registry's value is almost entirely in what it refuses, so the bulk of this file is refusal
 * cases: who may not call what, and which spends must not be allowed through. A registry that
 * happily registers agents but lets a compromised operator raise its own limit would pass a
 * happy-path suite and be worthless.
 */
contract AgentRegistryTest is Test {
    AgentRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal controller = makeAddr("controller");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal router = makeAddr("router");
    address internal stranger = makeAddr("stranger");
    address internal token = makeAddr("token");
    address internal otherToken = makeAddr("otherToken");

    uint256 internal constant MAX_PER_ACTION = 100e8;
    uint256 internal constant MAX_PER_EPOCH = 250e8;
    uint64 internal constant EPOCH = 1 days;

    uint256 internal agentId;

    function setUp() public {
        registry = new AgentRegistry(owner);

        vm.prank(owner);
        registry.setActionRouter(router);

        vm.prank(controller);
        agentId = registry.registerAgent(operator, treasury, "ipfs://agent");
    }

    function _setDefaultPolicy() internal {
        vm.prank(controller);
        registry.setSpendPolicy(agentId, token, MAX_PER_ACTION, MAX_PER_EPOCH, EPOCH);
    }

    // --- registration ---

    function test_RegisterAssignsCallerAsController() public view {
        AgentRegistry.Agent memory agent = registry.agentOf(agentId);
        assertEq(agent.controller, controller);
        assertEq(agent.operator, operator);
        assertEq(agent.treasury, treasury);
        assertEq(agent.metadataURI, "ipfs://agent");
        assertTrue(agent.active);
        assertEq(agent.registeredAt, uint64(block.timestamp));
    }

    /// @dev Ids start at 1 so that zero is never a valid agent and can be used as a sentinel.
    function test_AgentIdsStartAtOne() public view {
        assertEq(agentId, 1);
        assertEq(registry.agentCount(), 1);
    }

    function test_RegisterIncrementsIds() public {
        vm.prank(stranger);
        uint256 second = registry.registerAgent(operator, treasury, "ipfs://second");
        assertEq(second, 2);
        assertEq(registry.agentCount(), 2);
        assertEq(registry.agentOf(second).controller, stranger);
    }

    function test_RevertWhen_RegisteringWithZeroOperator() public {
        vm.expectRevert(AgentRegistry.AgentRegistry__ZeroAddress.selector);
        registry.registerAgent(address(0), treasury, "");
    }

    function test_RevertWhen_RegisteringWithZeroTreasury() public {
        vm.expectRevert(AgentRegistry.AgentRegistry__ZeroAddress.selector);
        registry.registerAgent(operator, address(0), "");
    }

    function test_RevertWhen_ReadingUnknownAgent() public {
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__UnknownAgent.selector, uint256(99)));
        registry.agentOf(99);
    }

    // --- default deny ---

    /// @dev The single most important property here: registration grants no spending ability.
    function test_RevertWhen_SpendingWithNoPolicySet() public {
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NoPolicy.selector, agentId, token));
        registry.authorizeSpend(agentId, operator, token, 1);
    }

    /// @dev A policy on one token must not authorise another.
    function test_RevertWhen_SpendingTokenWithoutItsOwnPolicy() public {
        _setDefaultPolicy();
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NoPolicy.selector, agentId, otherToken));
        registry.authorizeSpend(agentId, operator, otherToken, 1);
    }

    // --- authority separation ---

    function test_RevertWhen_NonControllerSetsPolicy() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotController.selector, agentId, stranger));
        registry.setSpendPolicy(agentId, token, 1, 1, EPOCH);
    }

    /// @dev The property the three-role split exists to guarantee: a compromised hot key cannot
    ///      raise its own ceiling.
    function test_RevertWhen_OperatorSetsOwnPolicy() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotController.selector, agentId, operator));
        registry.setSpendPolicy(agentId, token, type(uint256).max, type(uint256).max, EPOCH);
    }

    function test_RevertWhen_OperatorRotatesOperator() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotController.selector, agentId, operator));
        registry.setOperator(agentId, stranger);
    }

    function test_RevertWhen_OperatorRedirectsTreasury() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotController.selector, agentId, operator));
        registry.setTreasury(agentId, stranger);
    }

    function test_RevertWhen_NonRouterAuthorizesSpend() public {
        _setDefaultPolicy();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotRouter.selector, stranger));
        registry.authorizeSpend(agentId, operator, token, 1);
    }

    /// @dev Even the controller cannot record spend — only the router may.
    function test_RevertWhen_ControllerAuthorizesSpend() public {
        _setDefaultPolicy();
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotRouter.selector, controller));
        registry.authorizeSpend(agentId, operator, token, 1);
    }

    function test_RevertWhen_NonOwnerSetsRouter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setActionRouter(stranger);
    }

    // --- operator rotation ---

    function test_RotatingOperatorRevokesTheOldKey() public {
        _setDefaultPolicy();

        vm.prank(controller);
        registry.setOperator(agentId, stranger);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotOperator.selector, agentId, operator));
        registry.authorizeSpend(agentId, operator, token, 1);

        vm.prank(router);
        registry.authorizeSpend(agentId, stranger, token, 1);
    }

    /// @dev A stranger presented as the operator is rejected as an operator problem, not a
    ///      controller problem. The distinction matters when reading back a failed action.
    function test_RevertWhen_SpendAuthorizedForWrongOperator() public {
        _setDefaultPolicy();
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotOperator.selector, agentId, stranger));
        registry.authorizeSpend(agentId, stranger, token, 1);
    }

    function test_IsAuthorizedOperatorTracksRotation() public {
        assertTrue(registry.isAuthorizedOperator(agentId, operator));
        assertFalse(registry.isAuthorizedOperator(agentId, stranger));

        vm.prank(controller);
        registry.setOperator(agentId, stranger);

        assertFalse(registry.isAuthorizedOperator(agentId, operator));
        assertTrue(registry.isAuthorizedOperator(agentId, stranger));
    }

    function test_IsAuthorizedOperatorIsFalseForUnknownAgent() public view {
        assertFalse(registry.isAuthorizedOperator(12345, operator));
    }

    // --- deactivation ---

    function test_RevertWhen_SpendingWhileInactive() public {
        _setDefaultPolicy();

        vm.prank(controller);
        registry.setActive(agentId, false);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__AgentInactive.selector, agentId));
        registry.authorizeSpend(agentId, operator, token, 1);
    }

    function test_ReactivationRestoresSpending() public {
        _setDefaultPolicy();

        vm.startPrank(controller);
        registry.setActive(agentId, false);
        registry.setActive(agentId, true);
        vm.stopPrank();

        vm.prank(router);
        registry.authorizeSpend(agentId, operator, token, 1);
        assertEq(registry.spentThisEpoch(agentId, token), 1);
    }

    // --- policy validation ---

    function test_RevertWhen_PolicyHasZeroEpochDuration() public {
        vm.prank(controller);
        vm.expectRevert(AgentRegistry.AgentRegistry__InvalidPolicy.selector);
        registry.setSpendPolicy(agentId, token, 1, 1, 0);
    }

    /// @dev A per-action cap above the epoch cap is incoherent and almost always a typo.
    function test_RevertWhen_PerActionExceedsPerEpoch() public {
        vm.prank(controller);
        vm.expectRevert(AgentRegistry.AgentRegistry__InvalidPolicy.selector);
        registry.setSpendPolicy(agentId, token, 10, 5, EPOCH);
    }

    function test_RevertWhen_PolicySetOnZeroToken() public {
        vm.prank(controller);
        vm.expectRevert(AgentRegistry.AgentRegistry__ZeroAddress.selector);
        registry.setSpendPolicy(agentId, address(0), 1, 1, EPOCH);
    }

    // --- budget enforcement ---

    function test_SpendWithinCapsSucceeds() public {
        _setDefaultPolicy();
        vm.prank(router);
        registry.authorizeSpend(agentId, operator, token, MAX_PER_ACTION);
        assertEq(registry.spentThisEpoch(agentId, token), MAX_PER_ACTION);
    }

    function test_RevertWhen_SingleActionExceedsPerActionCap() public {
        _setDefaultPolicy();
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentRegistry.AgentRegistry__ExceedsPerAction.selector, MAX_PER_ACTION + 1, MAX_PER_ACTION
            )
        );
        registry.authorizeSpend(agentId, operator, token, MAX_PER_ACTION + 1);
    }

    function test_SpendAccumulatesWithinAnEpoch() public {
        _setDefaultPolicy();
        vm.startPrank(router);
        registry.authorizeSpend(agentId, operator, token, 100e8);
        registry.authorizeSpend(agentId, operator, token, 100e8);
        vm.stopPrank();
        assertEq(registry.spentThisEpoch(agentId, token), 200e8);
    }

    /// @dev Three actions each under the per-action cap must still be stopped by the epoch cap.
    function test_RevertWhen_AccumulatedSpendExceedsEpochCap() public {
        _setDefaultPolicy();
        vm.startPrank(router);
        registry.authorizeSpend(agentId, operator, token, 100e8);
        registry.authorizeSpend(agentId, operator, token, 100e8);

        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__ExceedsPerEpoch.selector, 100e8, 50e8));
        registry.authorizeSpend(agentId, operator, token, 100e8);
        vm.stopPrank();
    }

    function test_BudgetResetsInTheNextEpoch() public {
        _setDefaultPolicy();

        vm.startPrank(router);
        registry.authorizeSpend(agentId, operator, token, MAX_PER_ACTION);
        registry.authorizeSpend(agentId, operator, token, MAX_PER_ACTION);
        vm.stopPrank();
        assertEq(registry.spentThisEpoch(agentId, token), 200e8);

        vm.warp(block.timestamp + EPOCH);
        assertEq(registry.spentThisEpoch(agentId, token), 0);

        vm.prank(router);
        registry.authorizeSpend(agentId, operator, token, MAX_PER_ACTION);
        assertEq(registry.spentThisEpoch(agentId, token), MAX_PER_ACTION);
    }

    /// @dev Budgets are per token: exhausting one must not affect another.
    function test_BudgetsAreIndependentPerToken() public {
        _setDefaultPolicy();
        vm.prank(controller);
        registry.setSpendPolicy(agentId, otherToken, MAX_PER_ACTION, MAX_PER_EPOCH, EPOCH);

        vm.startPrank(router);
        registry.authorizeSpend(agentId, operator, token, MAX_PER_ACTION);
        registry.authorizeSpend(agentId, operator, otherToken, MAX_PER_ACTION);
        vm.stopPrank();

        assertEq(registry.spentThisEpoch(agentId, token), MAX_PER_ACTION);
        assertEq(registry.spentThisEpoch(agentId, otherToken), MAX_PER_ACTION);
    }

    /// @dev Lowering a cap mid-epoch must bite immediately rather than hand out a fresh budget.
    ///      This is the operation a controller reaches for during an incident.
    function test_LoweringCapMidEpochDoesNotResetSpend() public {
        _setDefaultPolicy();

        vm.prank(router);
        registry.authorizeSpend(agentId, operator, token, 100e8);

        vm.prank(controller);
        registry.setSpendPolicy(agentId, token, 50e8, 120e8, EPOCH);

        assertEq(registry.spentThisEpoch(agentId, token), 100e8);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentRegistry__ExceedsPerEpoch.selector, 50e8, 20e8));
        registry.authorizeSpend(agentId, operator, token, 50e8);
    }

    function test_SpentThisEpochIsZeroWithoutPolicy() public view {
        assertEq(registry.spentThisEpoch(agentId, token), 0);
    }

    // --- control transfer ---

    function test_TransferControlMovesAuthority() public {
        vm.prank(controller);
        registry.transferControl(agentId, stranger);

        assertEq(registry.agentOf(agentId).controller, stranger);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(AgentRegistry.AgentRegistry__NotController.selector, agentId, controller)
        );
        registry.setActive(agentId, false);

        vm.prank(stranger);
        registry.setActive(agentId, false);
        assertFalse(registry.agentOf(agentId).active);
    }

    // --- fuzz ---

    /// @dev Any single amount at or below the per-action cap is accepted; anything above is not.
    function testFuzz_PerActionCapIsExact(uint256 amount) public {
        _setDefaultPolicy();
        amount = bound(amount, 1, MAX_PER_EPOCH);

        vm.prank(router);
        if (amount > MAX_PER_ACTION) {
            vm.expectRevert(
                abi.encodeWithSelector(AgentRegistry.AgentRegistry__ExceedsPerAction.selector, amount, MAX_PER_ACTION)
            );
            registry.authorizeSpend(agentId, operator, token, amount);
        } else {
            registry.authorizeSpend(agentId, operator, token, amount);
            assertEq(registry.spentThisEpoch(agentId, token), amount);
        }
    }

    /// @dev No sequence of authorised spends may leave the epoch total above the epoch cap.
    function testFuzz_EpochTotalNeverExceedsCap(uint256[8] calldata amounts) public {
        _setDefaultPolicy();

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 0, MAX_PER_ACTION);
            if (amount == 0) continue;

            vm.prank(router);
            try registry.authorizeSpend(agentId, operator, token, amount) {
            // accepted
            }
                catch {
                // rejected — either cap bit, which is the point
            }
            assertLe(registry.spentThisEpoch(agentId, token), MAX_PER_EPOCH);
        }
    }
}
