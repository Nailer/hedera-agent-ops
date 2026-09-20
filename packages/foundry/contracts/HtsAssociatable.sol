// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IHederaTokenService } from "./interfaces/IHederaTokenService.sol";

/**
 * @title HtsAssociatable
 * @notice Lets an owner associate this contract with HTS tokens.
 *
 * @dev A Hedera account cannot hold an HTS token until it is associated, and that applies to
 * contracts exactly as it does to people. A transfer to an unassociated account fails with
 * `TOKEN_NOT_ASSOCIATED_TO_ACCOUNT` — at the moment of delivery, after the work is done.
 *
 * Every contract in this template that touches a token needs this: the router takes custody of both
 * the input and the output for the duration of a call, and each adapter receives the input before
 * it acts. Missing the association on any one of them breaks the flow at runtime while everything
 * compiles and every hermetic test passes, because a local EVM has no such concept.
 *
 * Association is idempotent here. HTS returns 194 (`TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT`) for a
 * token already associated, and that is treated as success so setup scripts can be re-run after a
 * partial failure without unpicking what already worked.
 */
abstract contract HtsAssociatable is Ownable {
    error HtsAssociatable__ZeroAddress();
    error HtsAssociatable__AssociationFailed(address token, int64 responseCode);

    event TokenAssociated(address indexed token);

    /// @dev The HTS system contract. Absent under a plain EVM fork — see AGENTS.md.
    address internal constant HTS = 0x0000000000000000000000000000000000000167;

    int64 internal constant HTS_SUCCESS = 22;
    int64 internal constant HTS_ALREADY_ASSOCIATED = 194;

    /// @dev Owns the `Ownable` wiring so inheritors do not each have to import and initialise it.
    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Associate this contract with one HTS token.
    function associate(address token) public onlyOwner {
        if (token == address(0)) revert HtsAssociatable__ZeroAddress();

        int64 responseCode = IHederaTokenService(HTS).associateToken(address(this), token);
        if (responseCode != HTS_SUCCESS && responseCode != HTS_ALREADY_ASSOCIATED) {
            revert HtsAssociatable__AssociationFailed(token, responseCode);
        }

        emit TokenAssociated(token);
    }

    /**
     * @notice Associate this contract with several tokens in one transaction.
     * @dev Each association is a separate HTS call rather than one `associateTokens` batch, so a
     *      single bad token names itself in the revert instead of failing the set anonymously.
     */
    function associateMany(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            associate(tokens[i]);
        }
    }
}
