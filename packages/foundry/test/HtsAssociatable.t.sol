// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { HtsAssociatable } from "../contracts/HtsAssociatable.sol";
import { ActionRouter } from "../contracts/ActionRouter.sol";
import { AgentRegistry } from "../contracts/AgentRegistry.sol";

/**
 * @notice Tests for the shared HTS association behaviour.
 *
 * The response-code branches are exercised hermetically by etching a stub at `0x167`, the address
 * the HTS system contract lives at on a real Hedera network. That lets the success, the benign
 * "already associated", and the genuine-failure paths all be tested without a fork — which matters,
 * because the branch that treats 194 as success is the one making setup scripts re-runnable, and it
 * would otherwise only ever be exercised by hand on testnet.
 */
contract HtsAssociatableTest is Test {
    ActionRouter internal router;
    AgentRegistry internal registry;
    HtsStub internal stub;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal tokenA = makeAddr("tokenA");
    address internal tokenB = makeAddr("tokenB");

    address internal constant HTS = 0x0000000000000000000000000000000000000167;

    function setUp() public {
        registry = new AgentRegistry(owner);
        router = new ActionRouter(owner, address(registry));

        stub = new HtsStub();
        vm.etch(HTS, address(stub).code);
    }

    function _setHtsResponse(int64 code) internal {
        HtsStub(HTS).setResponse(code);
    }

    // --- authority ---

    function test_RevertWhen_NonOwnerAssociates() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.associate(tokenA);
    }

    function test_RevertWhen_NonOwnerAssociatesMany() public {
        address[] memory tokens = new address[](1);
        tokens[0] = tokenA;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.associateMany(tokens);
    }

    function test_RevertWhen_AssociatingZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(HtsAssociatable.HtsAssociatable__ZeroAddress.selector);
        router.associate(address(0));
    }

    // --- response codes ---

    function test_AssociationSucceedsOnCode22() public {
        _setHtsResponse(22);

        vm.expectEmit(true, false, false, false);
        emit HtsAssociatable.TokenAssociated(tokenA);

        vm.prank(owner);
        router.associate(tokenA);
    }

    /// @dev 194 is TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT. Treating it as success is what lets a setup
    ///      script be re-run after a partial failure without unpicking what already worked.
    function test_AlreadyAssociatedIsTreatedAsSuccess() public {
        _setHtsResponse(194);

        vm.prank(owner);
        router.associate(tokenA);
    }

    function test_RevertWhen_HtsReturnsAFailureCode() public {
        _setHtsResponse(167);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HtsAssociatable.HtsAssociatable__AssociationFailed.selector, tokenA, int64(167))
        );
        router.associate(tokenA);
    }

    function testFuzz_AnyCodeOtherThan22Or194Reverts(int64 code) public {
        vm.assume(code != 22 && code != 194);
        _setHtsResponse(code);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HtsAssociatable.HtsAssociatable__AssociationFailed.selector, tokenA, code)
        );
        router.associate(tokenA);
    }

    // --- batch ---

    function test_AssociateManyAssociatesEach() public {
        _setHtsResponse(22);
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;

        vm.prank(owner);
        router.associateMany(tokens);

        assertEq(HtsStub(HTS).callCount(), 2, "each token must be associated individually");
    }

    /// @dev One bad token names itself rather than failing the batch anonymously.
    function test_RevertWhen_AssociateManyHitsAZeroAddress() public {
        _setHtsResponse(22);
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = address(0);

        vm.prank(owner);
        vm.expectRevert(HtsAssociatable.HtsAssociatable__ZeroAddress.selector);
        router.associateMany(tokens);
    }

    function test_AssociateManyWithEmptyListIsANoop() public {
        address[] memory tokens = new address[](0);

        vm.prank(owner);
        router.associateMany(tokens);

        assertEq(HtsStub(HTS).callCount(), 0);
    }
}

/**
 * @notice Stand-in for the HTS system contract, etched at 0x167.
 * @dev Only `associateToken` is needed. Storage slot 0 holds the response code and slot 1 a call
 *      counter, both readable after `vm.etch` because etch copies code, not storage.
 */
contract HtsStub {
    int64 public response;
    uint256 public callCount;

    function setResponse(int64 code) external {
        response = code;
    }

    function associateToken(address, address) external returns (int64) {
        callCount++;
        return response;
    }
}
