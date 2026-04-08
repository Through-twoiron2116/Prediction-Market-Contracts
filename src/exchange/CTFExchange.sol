// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Auth} from "./mixins/Auth.sol";
import {Assets} from "./mixins/Assets.sol";
import {Fees} from "./mixins/Fees.sol";
import {NonceManager} from "./mixins/NonceManager.sol";
import {Pausable} from "./mixins/Pausable.sol";
import {Registry} from "./mixins/Registry.sol";
import {Signing} from "./mixins/Signing.sol";
import {Trading} from "./mixins/Trading.sol";
import {Order} from "./mixins/OrderStructs.sol";

/**
 * @title CTFExchange
 * @notice Polymarket-style hybrid CLOB exchange for binary conditional token markets.
 *
 *  - Operators match orders off-chain and submit settlement transactions on-chain.
 *  - Supports direct fills (fillOrder) and multi-maker matching (matchOrders).
 *  - Three match types: COMPLEMENTARY (swap), MINT (both buy → split), MERGE (both sell → merge).
 *  - Fees in basis points, capped at 10%.
 *  - Emergency pause, admin/operator roles, per-user nonce cancellation.
 *
 * Deployed on Arbitrum and Abstract.
 */
contract CTFExchange is ERC1155Holder, ReentrancyGuard, Auth, Trading {
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Address that receives exchange fees
    address public feeReceiver;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _collateral  USDC (or wrapped USDC) address
     * @param _ctf         ConditionalTokens contract address
     * @param _feeReceiverAddr Initial fee collector address
     */
    constructor(address _collateral, address _ctf, address _feeReceiverAddr)
        Assets(_collateral, _ctf)
        Signing()
        Auth()
    {
        require(_feeReceiverAddr != address(0), "CTFExchange: zero feeReceiver");
        feeReceiver = _feeReceiverAddr;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setFeeReceiver(address _feeReceiverAddr) external onlyAdmin {
        require(_feeReceiverAddr != address(0), "CTFExchange: zero address");
        feeReceiver = _feeReceiverAddr;
    }

    function pauseTrading() external onlyAdmin {
        _pauseTrading();
    }

    function unpauseTrading() external onlyAdmin {
        _unpauseTrading();
    }

    /**
     * @notice Register a complementary token pair for a binary market.
     * @param token0      ERC-1155 position ID for outcome 0 (NO)
     * @param token1      ERC-1155 position ID for outcome 1 (YES)
     * @param conditionId CTF conditionId these tokens belong to
     */
    function registerToken(uint256 token0, uint256 token1, bytes32 conditionId) external onlyAdmin {
        _registerToken(token0, token1, conditionId);
    }

    // =========================================================================
    // Trading — operator entry points
    // =========================================================================

    /**
     * @notice Fill a single resting order on behalf of a taker.
     *         msg.sender must be an operator.
     * @param order      The resting order
     * @param fillAmount Amount of maker's makerAmount to fill
     */
    function fillOrder(Order calldata order, uint256 fillAmount) external nonReentrant onlyOperator {
        _fillOrder(order, fillAmount, msg.sender);
    }

    /**
     * @notice Fill multiple resting orders in a single transaction.
     */
    function fillOrders(Order[] calldata orders, uint256[] calldata fillAmounts)
        external
        nonReentrant
        onlyOperator
    {
        _fillOrders(orders, fillAmounts, msg.sender);
    }

    /**
     * @notice Atomically match a taker order against one or more maker orders.
     *         Operator provides pre-computed fill amounts.
     */
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
