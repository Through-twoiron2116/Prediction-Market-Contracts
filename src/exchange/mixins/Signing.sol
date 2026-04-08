// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Order, SignatureType} from "./OrderStructs.sol";

/**
 * @title Signing
 * @notice EIP-712 order hashing and multi-format signature verification.
 *         Supports: EOA (ECDSA), Polymarket proxy wallet, Gnosis Safe, ERC-1271.
 */
abstract contract Signing {
    // =========================================================================
    // EIP-712 Domain
    // =========================================================================

    bytes32 private immutable _DOMAIN_SEPARATOR;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint256 feeRateBps,uint8 side,uint8 signatureType)"
    );

    constructor() {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CTFExchange"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // =========================================================================
    // Hashing
    // =========================================================================

    function getDomainSeparator() public view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    function hashOrder(Order memory order) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        ORDER_TYPEHASH,
                        order.salt,
                        order.maker,
                        order.signer,
                        order.taker,
                        order.tokenId,
                        order.makerAmount,
                        order.takerAmount,
                        order.expiration,
                        order.nonce,
                        order.feeRateBps,
                        order.side,
                        order.signatureType
                    )
                )
            )
        );
    }

    // =========================================================================
    // Signature Verification
    // =========================================================================

    /// @notice Verify that `order.signer` authorized `orderHash`
    function _verifySignature(Order memory order, bytes32 orderHash) internal view {
        address signer = order.signer == address(0) ? order.maker : order.signer;

        if (order.signatureType == SignatureType.EOA) {
            address recovered = ECDSA.recover(orderHash, order.signature);
            require(recovered == signer, "Signing: invalid EOA signature");
        } else if (
            order.signatureType == SignatureType.POLY_PROXY
                || order.signatureType == SignatureType.POLY_GNOSIS_SAFE
        ) {
            // For proxy and Safe wallets the signer field must match
            // the proxy/safe address; we verify via ERC-1271
            _verify1271(signer, orderHash, order.signature);
        } else if (order.signatureType == SignatureType.POLY_1271) {
            _verify1271(signer, orderHash, order.signature);
        } else {
            revert("Signing: unknown signature type");
        }
    }

    function _verify1271(address signer, bytes32 hash, bytes memory sig) internal view {
        bytes4 result = IERC1271(signer).isValidSignature(hash, sig);
        require(result == IERC1271.isValidSignature.selector, "Signing: invalid 1271 signature");
    }
}
