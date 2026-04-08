// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Auth} from "../exchange/mixins/Auth.sol";
import {Assets} from "../exchange/mixins/Assets.sol";
import {Fees} from "../exchange/mixins/Fees.sol";
import {NonceManager} from "../exchange/mixins/NonceManager.sol";
import {Pausable} from "../exchange/mixins/Pausable.sol";
import {Registry} from "../exchange/mixins/Registry.sol";
import {Signing} from "../exchange/mixins/Signing.sol";
import {Trading} from "../exchange/mixins/Trading.sol";
import {Order} from "../exchange/mixins/OrderStructs.sol";
import {NegRiskAdapter} from "./NegRiskAdapter.sol";

/**
 * @title NegRiskCTFExchange
 * @notice Exchange for neg-risk (multi-outcome categorical) conditional token markets.
 *
 *         Extends CTFExchange with:
 *         - Awareness of the NegRiskAdapter for position conversions
 *         - Token registration uses the adapter's wrapped collateral
 *         - Same operator/admin model as CTFExchange
 */
contract NegRiskCTFExchange is ERC1155Holder, ReentrancyGuard, Auth, Trading {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    address public feeReceiver;
    NegRiskAdapter public immutable negRiskAdapter;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _collateral     Wrapped collateral (wcol from NegRiskAdapter)
     * @param _ctf            ConditionalTokens contract
     * @param _negRiskAdapter NegRiskAdapter contract
     * @param _feeReceiverAddr Initial fee receiver
     */
    constructor(
        address _collateral,
        address _ctf,
        address _negRiskAdapter,
        address _feeReceiverAddr
    ) Assets(_collateral, _ctf) Signing() Auth() {
        require(_negRiskAdapter != address(0), "NREx: zero adapter");
        require(_feeReceiverAddr != address(0), "NREx: zero feeReceiver");
        negRiskAdapter = NegRiskAdapter(_negRiskAdapter);
        feeReceiver = _feeReceiverAddr;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setFeeReceiver(address _feeReceiverAddr) external onlyAdmin {
        require(_feeReceiverAddr != address(0), "NREx: zero address");
        feeReceiver = _feeReceiverAddr;
    }

    function pauseTrading() external onlyAdmin {
        _pauseTrading();
    }

    function unpauseTrading() external onlyAdmin {
        _unpauseTrading();
    }

    function registerToken(uint256 token0, uint256 token1, bytes32 conditionId) external onlyAdmin {
        _registerToken(token0, token1, conditionId);
    }

    // =========================================================================
    // Trading
    // =========================================================================

    function fillOrder(Order calldata order, uint256 fillAmount)
        external
        nonReentrant
        onlyOperator
    {
        _fillOrder(order, fillAmount, msg.sender);
    }

    function fillOrders(Order[] calldata orders, uint256[] calldata fillAmounts)
        external
        nonReentrant
        onlyOperator
    {
        _fillOrders(orders, fillAmounts, msg.sender);
    }

    function matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) external nonReentrant onlyOperator {
        _matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
    }

    // =========================================================================
    // Internal overrides
    // =========================================================================

    function _feeReceiver() internal view override returns (address) {
        return feeReceiver;
    }
}
