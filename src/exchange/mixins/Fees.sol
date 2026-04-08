// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Fees
 * @notice Fee constants and calculation helpers.
 *         Max fee is 10% (1000 bps). Fees are charged to the taker.
 */
abstract contract Fees {
    uint256 public constant MAX_FEE_RATE_BIPS = 1_000; // 10%
    uint256 internal constant BPS = 10_000;

    event FeeCharged(address indexed receiver, uint256 tokenId, uint256 amount);

    function getMaxFeeRate() external pure returns (uint256) {
        return MAX_FEE_RATE_BIPS;
    }

    /// @dev Compute fee amount from a fill amount and fee rate in bps
    function _computeFee(uint256 amount, uint256 feeRateBps) internal pure returns (uint256) {
        if (feeRateBps == 0) return 0;
        return (amount * feeRateBps) / BPS;
    }
}
