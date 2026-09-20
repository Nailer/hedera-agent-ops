// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BonzoAdapter } from "../contracts/adapters/BonzoAdapter.sol";
import { IAgentAction } from "../contracts/interfaces/IAgentAction.sol";
import { MockERC20 } from "./harnesses/MockERC20.sol";
import { MockBonzoLendingPool, MockBonzoDataProvider } from "./harnesses/MockBonzo.sol";

/**
 * @notice Tests for BonzoAdapter.
 *
 * The weight is on asset validation, for the same reason as the SaucerSwap adapter: the registry
 * charges budget against `assetIn` and the router measures `assetOut`, but nothing upstream checks
 * those two are actually the underlying/aToken pair they claim to be. That check lives here.
 */
contract BonzoAdapterTest is Test {
    BonzoAdapter internal adapter;
    MockBonzoLendingPool internal pool;
    MockBonzoDataProvider internal dataProvider;

    MockERC20 internal underlying;
    MockERC20 internal aToken;
    MockERC20 internal unlisted;
    MockERC20 internal wrongToken;

    address internal owner = makeAddr("owner");
    address internal actionRouter = makeAddr("actionRouter");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND");
        aToken = new MockERC20("aUnderlying", "aUND");
        unlisted = new MockERC20("Unlisted", "UNL");
        wrongToken = new MockERC20("Wrong", "WRG");

        dataProvider = new MockBonzoDataProvider();
        dataProvider.setReserve(address(underlying), address(aToken));

        pool = new MockBonzoLendingPool(dataProvider);
        adapter = new BonzoAdapter(owner, address(pool), address(dataProvider));

        // The router transfers input to the adapter before calling execute.
        underlying.mint(address(adapter), 1_000_000e6);
        // The pool holds liquidity to pay withdrawals out of.
        underlying.mint(address(pool), 1_000_000e6);
    }

    function _supplyRequest(address assetIn, address assetOut)
        internal
        view
        returns (IAgentAction.ActionRequest memory)
    {
        return IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Supply,
            assetIn: assetIn,
            amountIn: AMOUNT,
            assetOut: assetOut,
            minAmountOut: 0,
            protocolData: ""
        });
    }

    function _withdrawRequest(address assetIn, address assetOut)
        internal
        view
        returns (IAgentAction.ActionRequest memory)
    {
        return IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Withdraw,
            assetIn: assetIn,
            amountIn: AMOUNT,
            assetOut: assetOut,
            minAmountOut: 0,
            protocolData: ""
        });
    }

    function _repayRequest(address assetIn, address assetOut, uint256 amount, bytes memory protocolData)
        internal
        pure
        returns (IAgentAction.ActionRequest memory)
    {
        return IAgentAction.ActionRequest({
            kind: IAgentAction.ActionKind.Repay,
            assetIn: assetIn,
            amountIn: amount,
            assetOut: assetOut,
            minAmountOut: 0,
            protocolData: protocolData
        });
    }

    // --- capabilities ---

    function test_ProtocolIdIsStable() public view {
        assertEq(adapter.protocolId(), bytes32("bonzo-v1"));
    }

    /// @dev Borrow is deliberately unsupported: the router pulls an input before calling an
    ///      adapter, and borrowing has no input. Declaring it false lets the router refuse early.
    function test_SupportsLendingActionsButNotBorrow() public view {
        assertTrue(adapter.supportsAction(IAgentAction.ActionKind.Supply));
        assertTrue(adapter.supportsAction(IAgentAction.ActionKind.Withdraw));
        assertTrue(adapter.supportsAction(IAgentAction.ActionKind.Repay));
        assertFalse(adapter.supportsAction(IAgentAction.ActionKind.Borrow));
        assertFalse(adapter.supportsAction(IAgentAction.ActionKind.Swap));
    }

    function test_RevertWhen_ExecutingBorrow() public {
        IAgentAction.ActionRequest memory request = _supplyRequest(address(underlying), address(aToken));
        request.kind = IAgentAction.ActionKind.Borrow;

        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentAction.IAgentAction__UnsupportedAction.selector, IAgentAction.ActionKind.Borrow
            )
        );
        adapter.execute(request, treasury);
    }

    function test_RevertWhen_ExecutingSwap() public {
        IAgentAction.ActionRequest memory request = _supplyRequest(address(underlying), address(aToken));
        request.kind = IAgentAction.ActionKind.Swap;

        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentAction.IAgentAction__UnsupportedAction.selector, IAgentAction.ActionKind.Swap)
        );
        adapter.execute(request, treasury);
    }

    function test_RevertWhen_ConstructedWithZeroAddresses() public {
        vm.expectRevert(BonzoAdapter.BonzoAdapter__ZeroAddress.selector);
        new BonzoAdapter(owner, address(0), address(dataProvider));

        vm.expectRevert(BonzoAdapter.BonzoAdapter__ZeroAddress.selector);
        new BonzoAdapter(owner, address(pool), address(0));
    }

    // --- supply ---

    function test_SupplyMintsATokensToTheRouter() public {
        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result =
            adapter.execute(_supplyRequest(address(underlying), address(aToken)), treasury);

        assertEq(aToken.balanceOf(actionRouter), AMOUNT, "aTokens must go to the caller");
        assertEq(pool.lastDepositOnBehalfOf(), actionRouter);
        assertEq(result.amountOut, AMOUNT);
        assertEq(result.assetOut, address(aToken));
    }

    /**
     * @dev The check that makes the spend policy mean something. Declaring an unrelated token as
     *      `assetOut` would have the router measure a delta in a token the deposit never produced.
     */
    function test_RevertWhen_SupplyAssetOutIsNotTheAToken() public {
        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                BonzoAdapter.BonzoAdapter__AssetOutIsNotTheAToken.selector, address(wrongToken), address(aToken)
            )
        );
        adapter.execute(_supplyRequest(address(underlying), address(wrongToken)), treasury);
    }

    function test_RevertWhen_SupplyingAnUnlistedReserve() public {
        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(BonzoAdapter.BonzoAdapter__ReserveNotListed.selector, address(unlisted)));
        adapter.execute(_supplyRequest(address(unlisted), address(aToken)), treasury);
    }

    function test_SupplyLeavesNoStandingAllowance() public {
        vm.prank(actionRouter);
        adapter.execute(_supplyRequest(address(underlying), address(aToken)), treasury);

        assertEq(underlying.allowance(address(adapter), address(pool)), 0);
    }

    // --- withdraw ---

    function test_WithdrawBurnsATokensAndReturnsUnderlying() public {
        // The router sends the agent's aTokens in before calling.
        aToken.mint(address(adapter), AMOUNT);

        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result =
            adapter.execute(_withdrawRequest(address(aToken), address(underlying)), treasury);

        assertEq(aToken.balanceOf(address(adapter)), 0, "aTokens must be burned from the adapter");
        assertEq(underlying.balanceOf(actionRouter), AMOUNT, "underlying must go to the caller");
        assertEq(pool.lastWithdrawTo(), actionRouter);
        assertEq(result.amountOut, AMOUNT);
    }

    function test_RevertWhen_WithdrawAssetInIsNotTheAToken() public {
        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                BonzoAdapter.BonzoAdapter__AssetInIsNotTheAToken.selector, address(wrongToken), address(aToken)
            )
        );
        adapter.execute(_withdrawRequest(address(wrongToken), address(underlying)), treasury);
    }

    function test_RevertWhen_WithdrawingAnUnlistedReserve() public {
        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(BonzoAdapter.BonzoAdapter__ReserveNotListed.selector, address(unlisted)));
        adapter.execute(_withdrawRequest(address(aToken), address(unlisted)), treasury);
    }

    // --- repay ---

    function test_RepayClearsDebtForTheTreasury() public {
        pool.setDebt(treasury, address(underlying), 60e6);

        vm.prank(actionRouter);
        adapter.execute(_repayRequest(address(underlying), address(underlying), 60e6, ""), treasury);

        assertEq(pool.debtOf(treasury, address(underlying)), 0);
        assertEq(pool.lastRepayOnBehalfOf(), treasury, "debt must be cleared for the agent, not the adapter");
    }

    /// @dev Bonzo caps repayment at the outstanding debt, so overpayment must come back rather than
    ///      being stranded in the adapter. This is why repay uses the same asset on both sides.
    function test_RepayRefundsOverpaymentToTheRouter() public {
        pool.setDebt(treasury, address(underlying), 40e6);

        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result =
            adapter.execute(_repayRequest(address(underlying), address(underlying), 100e6, ""), treasury);

        assertEq(result.amountOut, 60e6, "excess must be reported as output");
        assertEq(underlying.balanceOf(actionRouter), 60e6, "excess must be returned to the caller");
        assertEq(pool.debtOf(treasury, address(underlying)), 0);
    }

    function test_RepayWithNoExcessReturnsZero() public {
        pool.setDebt(treasury, address(underlying), 100e6);

        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result =
            adapter.execute(_repayRequest(address(underlying), address(underlying), 100e6, ""), treasury);

        assertEq(result.amountOut, 0);
        assertEq(underlying.balanceOf(actionRouter), 0);
    }

    function test_RepayDefaultsToVariableRateWhenDataIsEmpty() public {
        pool.setDebt(treasury, address(underlying), 50e6);

        vm.prank(actionRouter);
        adapter.execute(_repayRequest(address(underlying), address(underlying), 50e6, ""), treasury);

        assertEq(pool.lastRateMode(), 2, "empty protocolData must mean variable");
    }

    function test_RepayHonoursAnExplicitStableRateMode() public {
        pool.setDebt(treasury, address(underlying), 50e6);

        vm.prank(actionRouter);
        adapter.execute(_repayRequest(address(underlying), address(underlying), 50e6, abi.encode(uint256(1))), treasury);

        assertEq(pool.lastRateMode(), 1);
    }

    function test_RevertWhen_RepayRateModeIsInvalid() public {
        vm.prank(actionRouter);
        vm.expectRevert(abi.encodeWithSelector(BonzoAdapter.BonzoAdapter__InvalidRateMode.selector, uint256(3)));
        adapter.execute(_repayRequest(address(underlying), address(underlying), 50e6, abi.encode(uint256(3))), treasury);
    }

    function test_RevertWhen_RepayAssetsDiffer() public {
        vm.prank(actionRouter);
        vm.expectRevert(
            abi.encodeWithSelector(
                BonzoAdapter.BonzoAdapter__RepayAssetsMustMatch.selector, address(underlying), address(wrongToken)
            )
        );
        adapter.execute(_repayRequest(address(underlying), address(wrongToken), 50e6, ""), treasury);
    }

    function test_RepayLeavesNoStandingAllowance() public {
        pool.setDebt(treasury, address(underlying), 50e6);

        vm.prank(actionRouter);
        adapter.execute(_repayRequest(address(underlying), address(underlying), 50e6, ""), treasury);

        assertEq(underlying.allowance(address(adapter), address(pool)), 0);
    }

    // --- association ---

    function test_RevertWhen_NonOwnerAssociates() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.associate(address(underlying));
    }

    function test_RevertWhen_AssociatingZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BonzoAdapter.BonzoAdapter__ZeroAddress.selector);
        adapter.associate(address(0));
    }

    // --- fuzz ---

    /**
     * @dev Whatever the amount, repayment is capped at the debt and every token the adapter was
     *      given leaves it: `repaid` to the pool, the remainder back to the router. Nothing is
     *      stranded in the adapter, which is what "an adapter is a translator, not a vault" means
     *      in practice.
     */
    function testFuzz_RepayNeverStrandsFunds(uint256 debt, uint256 payment) public {
        debt = bound(debt, 0, 500_000e6);
        payment = bound(payment, 0, 500_000e6);
        pool.setDebt(treasury, address(underlying), debt);

        uint256 adapterBefore = underlying.balanceOf(address(adapter));
        uint256 routerBefore = underlying.balanceOf(actionRouter);

        vm.prank(actionRouter);
        IAgentAction.ActionResult memory result =
            adapter.execute(_repayRequest(address(underlying), address(underlying), payment, ""), treasury);

        uint256 expectedRepaid = payment > debt ? debt : payment;
        uint256 expectedRefund = payment - expectedRepaid;

        assertEq(result.amountOut, expectedRefund, "refund must be the unrepaid remainder");
        assertEq(underlying.balanceOf(actionRouter) - routerBefore, expectedRefund, "refund must reach the router");
        assertEq(
            adapterBefore - underlying.balanceOf(address(adapter)),
            payment,
            "everything the adapter was handed must leave it"
        );
        assertEq(pool.debtOf(treasury, address(underlying)), debt - expectedRepaid);
    }
}
