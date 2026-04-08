// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Auth} from "../exchange/mixins/Auth.sol";
import {Fees} from "../exchange/mixins/Fees.sol";

/**
 * @title NegRiskFeeModule
 * @notice Collects and distributes fees from the NegRiskCTFExchange.
 *         Admins can configure per-token fee rates and withdraw accumulated fees.
 */
contract NegRiskFeeModule is ERC1155Holder, Auth, Fees {
    // =========================================================================
    // State
    // =========================================================================

    address public immutable negRiskCtfExchange;
    address public immutable negRiskAdapter;
    address public immutable ctf;

    /// @notice feeRateBps per tokenId (0 = use default)
    mapping(uint256 => uint256) public tokenFeeRate;
    uint256 public defaultFeeRateBps;

    // =========================================================================
    // Events
    // =========================================================================

    event DefaultFeeRateSet(uint256 feeRateBps);
    event TokenFeeRateSet(uint256 indexed tokenId, uint256 feeRateBps);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event ERC1155FeesWithdrawn(address indexed token, address indexed to, uint256 id, uint256 amount);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _negRiskCtfExchange, address _negRiskAdapter, address _ctf)
        Auth()
    {
        require(_negRiskCtfExchange != address(0), "FeeModule: zero exchange");
        require(_negRiskAdapter != address(0), "FeeModule: zero adapter");
        require(_ctf != address(0), "FeeModule: zero ctf");

        negRiskCtfExchange = _negRiskCtfExchange;
        negRiskAdapter = _negRiskAdapter;
        ctf = _ctf;

        // Grant approvals so this module can handle tokens on behalf of the exchange
        IERC1155(_ctf).setApprovalForAll(_negRiskAdapter, true);
        IERC1155(_ctf).setApprovalForAll(_negRiskCtfExchange, true);
    }

    // =========================================================================
    // Configuration
    // =========================================================================

    function setDefaultFeeRate(uint256 feeRateBps) external onlyAdmin {
        require(feeRateBps <= MAX_FEE_RATE_BIPS, "FeeModule: exceeds max");
        defaultFeeRateBps = feeRateBps;
        emit DefaultFeeRateSet(feeRateBps);
    }

    function setTokenFeeRate(uint256 tokenId, uint256 feeRateBps) external onlyAdmin {
        require(feeRateBps <= MAX_FEE_RATE_BIPS, "FeeModule: exceeds max");
        tokenFeeRate[tokenId] = feeRateBps;
        emit TokenFeeRateSet(tokenId, feeRateBps);
    }

    function getFeeRate(uint256 tokenId) external view returns (uint256) {
        uint256 rate = tokenFeeRate[tokenId];
        return rate > 0 ? rate : defaultFeeRateBps;
    }

    // =========================================================================
    // Withdrawal (admin)
    // =========================================================================

    function withdrawERC20(address token, address to, uint256 amount) external onlyAdmin {
        IERC20(token).transfer(to, amount);
        emit FeesWithdrawn(token, to, amount);
    }

    function withdrawERC1155(address token, address to, uint256 id, uint256 amount) external onlyAdmin {
        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        emit ERC1155FeesWithdrawn(token, to, id, amount);
    }
}
