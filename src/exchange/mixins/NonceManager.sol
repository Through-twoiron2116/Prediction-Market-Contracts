// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title NonceManager
 * @notice Per-user sequential nonce for order cancellation.
 *         Incrementing a nonce invalidates all orders with the old nonce value.
 */
abstract contract NonceManager {
    event NonceIncremented(address indexed user, uint256 newNonce);

    mapping(address => uint256) public nonces;

    /// @notice Increment the caller's nonce, invalidating all open orders
    function incrementNonce() external {
        nonces[msg.sender]++;
        emit NonceIncremented(msg.sender, nonces[msg.sender]);
    }

    /// @notice Jump to a specific nonce value (must be > current)
    function updateNonce(uint256 newNonce) external {
        require(newNonce > nonces[msg.sender], "NonceManager: must increase");
        nonces[msg.sender] = newNonce;
        emit NonceIncremented(msg.sender, newNonce);
    }

    function isValidNonce(address user, uint256 nonce) public view returns (bool) {
        return nonces[user] == nonce;
    }
}
