// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Direction of the order from the maker's perspective
enum Side {
    BUY, // Maker wants to buy outcome tokens, spending collateral
    SELL // Maker wants to sell outcome tokens, receiving collateral
}

/// @notice How the order signature was produced
enum SignatureType {
    EOA, // Standard ECDSA
    POLY_PROXY, // Polymarket proxy wallet
    POLY_GNOSIS_SAFE, // Polymarket Gnosis Safe
    POLY_1271 // ERC-1271 contract signature
}

/// @notice A signed order to trade conditional tokens
struct Order {
    /// @dev Entropy — prevents replay of identical-looking orders
    uint256 salt;
    /// @dev Account whose token balance changes (may differ from signer for proxy wallets)
    address maker;
    /// @dev Account whose signature authorizes this order
    address signer;
    /// @dev Allowed taker; address(0) = anyone
    address taker;
    /// @dev ERC-1155 conditional token ID (position ID in the CTF)
    uint256 tokenId;
    /// @dev Amount of tokens (BUY) or collateral (SELL) the maker provides
    uint256 makerAmount;
    /// @dev Minimum amount of collateral (BUY) or tokens (SELL) the maker receives
    uint256 takerAmount;
    /// @dev Unix timestamp after which the order is invalid (0 = no expiry)
    uint256 expiration;
    /// @dev Nonce for order cancellation; must match user's current nonce
    uint256 nonce;
    /// @dev Fee rate in basis points charged to the taker; max 1000 (10%)
    uint256 feeRateBps;
    Side side;
    SignatureType signatureType;
    bytes signature;
}

/// @notice Tracks how much of an order has been filled
struct OrderStatus {
    bool isFilledOrCancelled;
    uint256 remaining;
}
