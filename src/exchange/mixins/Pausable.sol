// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Pausable
 * @notice Emergency circuit breaker for trading.
 */
abstract contract Pausable {
    event TradingPaused(address indexed sender);
    event TradingUnpaused(address indexed sender);

    bool public paused;

    modifier notPaused() {
        require(!paused, "Pausable: trading paused");
        _;
    }

    function _pauseTrading() internal {
        paused = true;
        emit TradingPaused(msg.sender);
    }

    function _unpauseTrading() internal {
        paused = false;
        emit TradingUnpaused(msg.sender);
    }
}
