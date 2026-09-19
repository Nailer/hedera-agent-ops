// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// Minimal interface for the HTS precompile at 0x167 (create fungible token + mint).
/// Struct layout matches the official IHederaTokenService for ABI compatibility.
interface IHederaTokenService {
    struct Expiry {
        int64 second;
        address autoRenewAccount;
        int64 autoRenewPeriod;
    }

    struct KeyValue {
        bool inheritAccountKey;
        address contractId;
        bytes ed25519;
        bytes ECDSA_secp256k1;
        address delegatableContractId;
    }

    struct TokenKey {
        uint256 keyType;
        KeyValue key;
    }

    struct HederaToken {
        string name;
        string symbol;
        address treasury;
        string memo;
        bool tokenSupplyType;
        int64 maxSupply;
        bool freezeDefault;
        TokenKey[] tokenKeys;
        Expiry expiry;
    }

    /// Creates a Fungible Token with the specified properties.
    /// @return responseCode SUCCESS is 22.
    /// @return tokenAddress The created token's address.
    function createFungibleToken(HederaToken memory token, int64 initialTotalSupply, int32 decimals)
        external
        payable
        returns (int64 responseCode, address tokenAddress);

    /// Mints an amount of the token to the treasury account.
    /// @param metadata For NFTs only; use empty array for fungible.
    /// @return responseCode SUCCESS is 22.
    function mintToken(address token, int64 amount, bytes[] memory metadata)
        external
        returns (int64 responseCode, int64 newTotalSupply, int64[] memory serialNumbers);

    /// Associates `account` with `token`. A Hedera account -- contracts included -- cannot hold an
    /// HTS token until it is associated, and a transfer to an unassociated account fails with
    /// TOKEN_NOT_ASSOCIATED_TO_ACCOUNT. Returns 22 (SUCCESS) or an HTS response code.
    function associateToken(address account, address token) external returns (int64 responseCode);
}
