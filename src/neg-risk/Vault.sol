// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Auth} from "../exchange/mixins/Auth.sol";

/**
 * @title Vault
 * @notice Accumulates fees from the NegRiskAdapter (USDC and YES tokens).
 *         Admins can withdraw via admin-controlled functions.
 */
contract Vault is ERC1155Holder, Auth {
    using SafeERC20 for IERC20;

    event ERC20Transferred(address indexed token, address indexed to, uint256 amount);
    event ERC1155Transferred(address indexed token, address indexed to, uint256 id, uint256 value);

    constructor() Auth() {}

    function transferERC20(address token, address to, uint256 amount) external onlyAdmin {
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Transferred(token, to, amount);
    }

    function transferERC1155(address token, address to, uint256 id, uint256 value) external onlyAdmin {
        IERC1155(token).safeTransferFrom(address(this), to, id, value, "");
        emit ERC1155Transferred(token, to, id, value);
    }

    function batchTransferERC1155(
        address token,
        address to,
        uint256[] calldata ids,
        uint256[] calldata values
    ) external onlyAdmin {
        IERC1155(token).safeBatchTransferFrom(address(this), to, ids, values, "");
    }
}
