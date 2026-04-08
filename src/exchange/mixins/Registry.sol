// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Registry
 * @notice Maps conditional token IDs to their complement and condition.
 *         Binary markets produce two tokens (YES / NO); each must be registered
 *         as a pair so the exchange can validate swaps and perform MINT/MERGE
 *         match types.
 */
abstract contract Registry {
    // =========================================================================
    // Types
    // =========================================================================

    struct OutcomeToken {
        uint256 complement; // The other token in the binary pair
        bytes32 conditionId; // The CTF condition they belong to
    }

    // =========================================================================
    // Events
    // =========================================================================

    event TokenRegistered(
        uint256 indexed token0, uint256 indexed token1, bytes32 indexed conditionId
    );

    // =========================================================================
    // State
    // =========================================================================

    /// @notice registry[tokenId] => OutcomeToken
    mapping(uint256 => OutcomeToken) public registry;

    // =========================================================================
    // Registration
    // =========================================================================

    function _registerToken(uint256 token0, uint256 token1, bytes32 conditionId) internal {
        require(token0 != token1, "Registry: identical tokens");
        require(registry[token0].conditionId == bytes32(0), "Registry: token0 already registered");
        require(registry[token1].conditionId == bytes32(0), "Registry: token1 already registered");

        registry[token0] = OutcomeToken({complement: token1, conditionId: conditionId});
        registry[token1] = OutcomeToken({complement: token0, conditionId: conditionId});

        emit TokenRegistered(token0, token1, conditionId);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function getConditionId(uint256 tokenId) public view returns (bytes32) {
        return registry[tokenId].conditionId;
    }

    function getComplement(uint256 tokenId) public view returns (uint256) {
        return registry[tokenId].complement;
    }

    function validateComplement(uint256 token, uint256 complement) public view returns (bool) {
        return registry[token].complement == complement && complement != 0;
    }

    function validateTokenId(uint256 tokenId) public view returns (bool) {
        return registry[tokenId].conditionId != bytes32(0);
    }
}
