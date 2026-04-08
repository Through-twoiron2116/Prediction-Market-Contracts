// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IConditionalTokens} from "../../interfaces/IConditionalTokens.sol";
import {Order, OrderStatus, Side} from "./OrderStructs.sol";
import {Assets} from "./Assets.sol";
import {Fees} from "./Fees.sol";
import {NonceManager} from "./NonceManager.sol";
import {Pausable} from "./Pausable.sol";
import {Registry} from "./Registry.sol";
import {Signing} from "./Signing.sol";

/**
 * @title Trading
 * @notice Core order validation, cancellation, and fill/match logic.
 *
 * Three match types:
 *  - COMPLEMENTARY: taker BUYs, maker SELLs the same token (token-for-collateral swap)
 *  - MINT:          taker BUYs token0, maker BUYs token1 → contract mints both from collateral
 *  - MERGE:         taker SELLs token0, maker SELLs token1 → contract burns both for collateral
 */
abstract contract Trading is Assets, Fees, NonceManager, Pausable, Registry, Signing {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    enum MatchType {
        COMPLEMENTARY,
        MINT,
        MERGE
    }

    // =========================================================================
    // Events
    // =========================================================================

    event OrderCancelled(bytes32 indexed orderHash);

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 tokenId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    );

    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        address indexed takerOrderMaker,
        uint256 tokenId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    );

    // =========================================================================
    // State
    // =========================================================================

    /// @notice orderHash => status
    mapping(bytes32 => OrderStatus) public orderStatus;

    // =========================================================================
    // Cancellation
    // =========================================================================

    function cancelOrder(Order calldata order) external {
        require(order.maker == msg.sender || order.signer == msg.sender, "Trading: not your order");
        bytes32 orderHash = hashOrder(order);
        require(!orderStatus[orderHash].isFilledOrCancelled, "Trading: already done");
        orderStatus[orderHash].isFilledOrCancelled = true;
        emit OrderCancelled(orderHash);
    }

    function cancelOrders(Order[] calldata orders) external {
        for (uint256 i = 0; i < orders.length; i++) {
            require(orders[i].maker == msg.sender || orders[i].signer == msg.sender, "Trading: not your order");
            bytes32 orderHash = hashOrder(orders[i]);
            if (!orderStatus[orderHash].isFilledOrCancelled) {
                orderStatus[orderHash].isFilledOrCancelled = true;
                emit OrderCancelled(orderHash);
            }
        }
    }

    // =========================================================================
    // Order Filling (operator-facing)
    // =========================================================================

    /**
     * @notice Fill a single order.
     * @param order      The order to fill
     * @param fillAmount Amount of takerAmount to fill
     * @param to         Recipient of the output asset
     */
    function _fillOrder(Order calldata order, uint256 fillAmount, address to) internal notPaused {
        (bytes32 orderHash, uint256 making, uint256 taking, uint256 fee) =
            _prepareOrder(order, fillAmount);

        _settleOrder(order, to, making, taking, fee);

        orderStatus[orderHash].remaining -= making;
        emit OrderFilled(orderHash, order.maker, to, order.tokenId, making, taking, fee);
    }

    /**
     * @notice Fill multiple orders, each with its own fill amount.
     */
    function _fillOrders(Order[] calldata orders, uint256[] calldata fillAmounts, address to)
        internal
        notPaused
    {
        require(orders.length == fillAmounts.length, "Trading: length mismatch");
        for (uint256 i = 0; i < orders.length; i++) {
            _fillOrder(orders[i], fillAmounts[i], to);
        }
    }

    /**
     * @notice Match a taker order against one or more maker orders.
     *         The operator provides the fill amounts to ensure atomic settlement.
     */
    function _matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) internal notPaused {
        require(makerOrders.length == makerFillAmounts.length, "Trading: length mismatch");

        (bytes32 takerHash,, uint256 takerTaking,) = _prepareOrder(takerOrder, takerFillAmount);

        uint256 totalMakerFill = 0;
        for (uint256 i = 0; i < makerOrders.length; i++) {
            _validateMatchedPair(takerOrder, makerOrders[i]);
            MatchType matchType = _getMatchType(takerOrder, makerOrders[i]);

            (bytes32 makerHash, uint256 makerMaking, uint256 makerTaking, uint256 makerFee) =
                _prepareOrder(makerOrders[i], makerFillAmounts[i]);

            _settleMatchedPair(takerOrder, makerOrders[i], makerMaking, makerTaking, makerFee, matchType);

            orderStatus[makerHash].remaining -= makerMaking;
            totalMakerFill += makerTaking;

            emit OrderFilled(makerHash, makerOrders[i].maker, takerOrder.maker, makerOrders[i].tokenId, makerMaking, makerTaking, makerFee);
        }

        require(totalMakerFill >= takerTaking, "Trading: taker under-filled");
        orderStatus[takerHash].remaining -= takerFillAmount;

        emit OrdersMatched(takerHash, takerOrder.maker, takerOrder.tokenId, takerFillAmount, takerTaking);
    }

    // =========================================================================
    // Internal: Validation
    // =========================================================================

    function _prepareOrder(Order calldata order, uint256 fillAmount)
        internal
        returns (bytes32 orderHash, uint256 making, uint256 taking, uint256 fee)
    {
        orderHash = hashOrder(order);
        _validateOrder(order, orderHash);

        OrderStatus storage status = orderStatus[orderHash];
        if (status.remaining == 0 && !status.isFilledOrCancelled) {
            // First time seeing this order — initialise remaining
            status.remaining = order.makerAmount;
        }

        require(!status.isFilledOrCancelled, "Trading: order done");
        require(fillAmount > 0, "Trading: zero fill");
        require(fillAmount <= status.remaining, "Trading: overfill");

        making = fillAmount;
        // Price ratio: takerAmount / makerAmount
        taking = (fillAmount * order.takerAmount) / order.makerAmount;
        fee = _computeFee(taking, order.feeRateBps);
    }

    function _validateOrder(Order calldata order, bytes32 orderHash) internal view {
        require(order.maker != address(0), "Trading: zero maker");
        require(order.makerAmount > 0 && order.takerAmount > 0, "Trading: zero amounts");
        require(order.expiration == 0 || order.expiration >= block.timestamp, "Trading: expired");
        require(order.taker == address(0) || order.taker == msg.sender, "Trading: wrong taker");
        require(isValidNonce(order.maker, order.nonce), "Trading: bad nonce");
        require(validateTokenId(order.tokenId), "Trading: unregistered token");
        require(order.feeRateBps <= MAX_FEE_RATE_BIPS, "Trading: fee too high");
        _verifySignature(order, orderHash);
    }

    function _validateMatchedPair(Order calldata takerOrder, Order calldata makerOrder) internal pure {
        require(takerOrder.side != makerOrder.side, "Trading: same side");
        // Taker and maker must reference the same or complementary token
        // (validated further inside _getMatchType)
    }

    function _getMatchType(Order calldata takerOrder, Order calldata makerOrder)
        internal
        view
        returns (MatchType)
    {
        if (takerOrder.tokenId == makerOrder.tokenId) {
            // Same token: one BUY, one SELL → direct swap
            return MatchType.COMPLEMENTARY;
        }
        uint256 takerComplement = getComplement(takerOrder.tokenId);
        require(takerComplement == makerOrder.tokenId, "Trading: unrelated tokens");

        // Different tokens that are complements of each other
        if (takerOrder.side == Side.BUY && makerOrder.side == Side.BUY) {
            return MatchType.MINT;
        }
        return MatchType.MERGE;
    }

    // =========================================================================
    // Internal: Settlement
    // =========================================================================

    /// @dev Settle a single order fill (taker calls fillOrder directly)
    function _settleOrder(Order calldata order, address to, uint256 making, uint256 taking, uint256 fee) internal {
        if (order.side == Side.BUY) {
            // Maker provides collateral, receives tokens
            IERC20(collateral).safeTransferFrom(order.maker, address(this), making);
            if (fee > 0) {
                IERC20(collateral).safeTransfer(_feeReceiver(), fee);
                emit FeeCharged(_feeReceiver(), order.tokenId, fee);
            }
            IERC1155(ctf).safeTransferFrom(to, order.maker, order.tokenId, taking, "");
        } else {
            // Maker provides tokens, receives collateral
            IERC1155(ctf).safeTransferFrom(order.maker, address(this), order.tokenId, making, "");
            uint256 payout = taking - fee;
            IERC20(collateral).safeTransfer(order.maker, payout);
            if (fee > 0) {
                IERC20(collateral).safeTransfer(_feeReceiver(), fee);
                emit FeeCharged(_feeReceiver(), order.tokenId, fee);
            }
        }
    }

    /// @dev Settle a matched pair of orders
    function _settleMatchedPair(
        Order calldata takerOrder,
        Order calldata makerOrder,
        uint256 makerMaking,
        uint256 makerTaking,
        uint256 makerFee,
        MatchType matchType
    ) internal {
        if (matchType == MatchType.COMPLEMENTARY) {
            if (takerOrder.side == Side.BUY) {
                // Taker buys tokens; maker sells tokens
                IERC20(collateral).safeTransferFrom(takerOrder.maker, makerOrder.maker, makerTaking - makerFee);
                if (makerFee > 0) {
                    IERC20(collateral).safeTransferFrom(takerOrder.maker, _feeReceiver(), makerFee);
                }
                IERC1155(ctf).safeTransferFrom(makerOrder.maker, takerOrder.maker, makerOrder.tokenId, makerMaking, "");
            } else {
                // Taker sells tokens; maker buys tokens
                IERC20(collateral).safeTransferFrom(makerOrder.maker, takerOrder.maker, makerMaking - makerFee);
                if (makerFee > 0) {
                    IERC20(collateral).safeTransferFrom(makerOrder.maker, _feeReceiver(), makerFee);
                }
                IERC1155(ctf).safeTransferFrom(takerOrder.maker, makerOrder.maker, takerOrder.tokenId, makerTaking, "");
            }
        } else if (matchType == MatchType.MINT) {
            // Both BUY: pull collateral from both, mint token pair
            IERC20(collateral).safeTransferFrom(takerOrder.maker, address(this), makerTaking);
            IERC20(collateral).safeTransferFrom(makerOrder.maker, address(this), makerMaking);
            _mintPositions(takerOrder.tokenId, makerOrder.tokenId, getConditionId(takerOrder.tokenId), makerMaking);
            IERC1155(ctf).safeTransferFrom(address(this), takerOrder.maker, takerOrder.tokenId, makerTaking, "");
            IERC1155(ctf).safeTransferFrom(address(this), makerOrder.maker, makerOrder.tokenId, makerMaking, "");
        } else {
            // MERGE: both SELL — receive tokens, burn for collateral
            IERC1155(ctf).safeTransferFrom(takerOrder.maker, address(this), takerOrder.tokenId, makerTaking, "");
            IERC1155(ctf).safeTransferFrom(makerOrder.maker, address(this), makerOrder.tokenId, makerMaking, "");
            _mergePositions(takerOrder.tokenId, makerOrder.tokenId, getConditionId(takerOrder.tokenId), makerMaking);
            IERC20(collateral).safeTransfer(takerOrder.maker, makerTaking - makerFee);
            IERC20(collateral).safeTransfer(makerOrder.maker, makerMaking - makerFee);
            if (makerFee > 0) {
                IERC20(collateral).safeTransfer(_feeReceiver(), makerFee * 2);
            }
        }
    }

    function _mintPositions(uint256 token0, uint256 token1, bytes32 conditionId, uint256 amount) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1; // indexSet for outcome 0 (NO / token0)
        partition[1] = 2; // indexSet for outcome 1 (YES / token1)
        IConditionalTokens(ctf).splitPosition(
            IERC20(collateral), bytes32(0), conditionId, partition, amount
        );
    }

    function _mergePositions(uint256 token0, uint256 token1, bytes32 conditionId, uint256 amount) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        IConditionalTokens(ctf).mergePositions(
            IERC20(collateral), bytes32(0), conditionId, partition, amount
        );
    }

    /// @dev Override in the main exchange to point to the fee collector address
    function _feeReceiver() internal view virtual returns (address) {
        return address(this);
    }
}
