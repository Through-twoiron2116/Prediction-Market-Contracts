// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Order, Side} from "../exchange/mixins/OrderStructs.sol";

interface ICTFExchange {
    function fillOrder(Order calldata order, uint256 fillAmount) external;
    function fillOrders(Order[] calldata orders, uint256[] calldata fillAmounts) external;
    function matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) external;
    function cancelOrder(Order calldata order) external;
    function cancelOrders(Order[] calldata orders) external;
    function registerToken(uint256 token0, uint256 token1, bytes32 conditionId) external;
    function pauseTrading() external;
    function unpauseTrading() external;
}
