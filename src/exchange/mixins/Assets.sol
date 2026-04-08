// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title Assets
 * @notice Stores immutable references to the collateral ERC-20 and the
 *         CTF ERC-1155 contract, and grants the CTF contract unlimited
 *         collateral approval so it can pull funds when splitting positions.
 */
abstract contract Assets {
    using SafeERC20 for IERC20;

    /// @notice USDC (or other stablecoin) used as collateral
    address public immutable collateral;

    /// @notice ConditionalTokens ERC-1155 contract
    address public immutable ctf;

    constructor(address _collateral, address _ctf) {
        require(_collateral != address(0), "Assets: zero collateral");
        require(_ctf != address(0), "Assets: zero ctf");
        collateral = _collateral;
        ctf = _ctf;
        // Approve CTF to pull collateral for splitPosition calls
        IERC20(_collateral).forceApprove(_ctf, type(uint256).max);
    }

    // =========================================================================
    // Internal Transfer Helpers
    // =========================================================================

    function _transferCollateral(address from, address to, uint256 amount) internal {
        if (from == address(this)) {
            IERC20(collateral).safeTransfer(to, amount);
        } else {
            IERC20(collateral).safeTransferFrom(from, to, amount);
        }
    }

    function _transferCTFTokens(address from, address to, uint256 tokenId, uint256 amount) internal {
        IERC1155(ctf).safeTransferFrom(from, to, tokenId, amount, "");
    }
}
