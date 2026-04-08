// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Auth} from "../exchange/mixins/Auth.sol";
import {NegRiskAdapter} from "./NegRiskAdapter.sol";

/**
 * @title NegRiskOperator
 * @notice Admin layer over NegRiskAdapter.
 *         Handles the market preparation workflow, oracle reporting, and
 *         emergency resolution — keeping these privileged operations separate
 *         from the adapter's core token logic.
 *
 * Resolution flow:
 *   1. Admin calls prepareMarket() and prepareQuestion()
 *   2. Oracle calls reportPayouts() (via oracle address)
 *   3. Admin calls resolveQuestion() to finalize
 *   4. In dispute → admin calls flagQuestion() to block normal resolution
 *   5. Admin can emergencyResolveQuestion() as override
 */
contract NegRiskOperator is Auth {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Delay after flagging before emergency resolution is allowed
    uint256 public constant EMERGENCY_RESOLUTION_DELAY = 2 days;

    // =========================================================================
    // State
    // =========================================================================

    NegRiskAdapter public immutable nrAdapter;
    address public oracle;

    mapping(bytes32 => bytes32) public requestIdToQuestionId;
    mapping(bytes32 => bool) public results;
    mapping(bytes32 => uint256) public flaggedAt;
    mapping(bytes32 => uint256) public reportedAt;

    // =========================================================================
    // Events
    // =========================================================================

    event OracleSet(address indexed oracle);
    event MarketPrepared(bytes32 indexed marketId, uint256 feeBips, bytes data);
    event QuestionPrepared(
        bytes32 indexed marketId, bytes32 indexed questionId, bytes32 indexed requestId, bytes data
    );
    event QuestionReported(bytes32 indexed questionId, bool outcome);
    event QuestionResolved(bytes32 indexed questionId);
    event QuestionFlagged(bytes32 indexed questionId);
    event QuestionUnflagged(bytes32 indexed questionId);
    event QuestionEmergencyResolved(bytes32 indexed questionId, bool outcome);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _nrAdapter) Auth() {
        require(_nrAdapter != address(0), "NRO: zero adapter");
        nrAdapter = NegRiskAdapter(_nrAdapter);
    }

    // =========================================================================
    // Configuration
    // =========================================================================

    /// @notice Set the oracle address (one-time, admin only)
    function setOracle(address _oracle) external onlyAdmin {
        require(oracle == address(0), "NRO: oracle already set");
        require(_oracle != address(0), "NRO: zero oracle");
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    // =========================================================================
    // Market Lifecycle
    // =========================================================================

    function prepareMarket(uint256 feeBips, bytes calldata data) external onlyAdmin returns (bytes32 marketId) {
        marketId = nrAdapter.prepareMarket(feeBips, data);
        emit MarketPrepared(marketId, feeBips, data);
    }

    function prepareQuestion(bytes32 marketId, bytes calldata data, bytes32 requestId)
        external
        onlyAdmin
        returns (bytes32 questionId)
    {
        questionId = nrAdapter.prepareQuestion(marketId, data);
        requestIdToQuestionId[requestId] = questionId;
        emit QuestionPrepared(marketId, questionId, requestId, data);
    }

    // =========================================================================
    // Oracle Resolution
    // =========================================================================

    /**
     * @notice Called by the oracle with a binary result for a question.
     *         payouts[0]=1,payouts[1]=0 → NO won; payouts[0]=0,payouts[1]=1 → YES won
     */
    function reportPayouts(bytes32 requestId, uint256[] calldata payouts) external {
        require(msg.sender == oracle, "NRO: not oracle");
        require(payouts.length == 2, "NRO: invalid payouts");

        bytes32 questionId = requestIdToQuestionId[requestId];
        require(questionId != bytes32(0), "NRO: unknown requestId");
        require(reportedAt[questionId] == 0, "NRO: already reported");
        require(flaggedAt[questionId] == 0, "NRO: question flagged");

        bool outcome = payouts[1] == 1;
        results[questionId] = outcome;
        reportedAt[questionId] = block.timestamp;

        emit QuestionReported(questionId, outcome);
    }

    /**
     * @notice Finalize a reported (unflagged) question by pushing to the adapter.
     */
    function resolveQuestion(bytes32 questionId) external onlyAdmin {
        require(reportedAt[questionId] > 0, "NRO: not reported");
        require(flaggedAt[questionId] == 0, "NRO: flagged");

        nrAdapter.reportOutcome(questionId, results[questionId]);
        emit QuestionResolved(questionId);
    }

    /**
     * @notice Flag a question to prevent normal resolution (e.g., disputed result).
     */
    function flagQuestion(bytes32 questionId) external onlyAdmin {
        require(flaggedAt[questionId] == 0, "NRO: already flagged");
        flaggedAt[questionId] = block.timestamp;
        emit QuestionFlagged(questionId);
    }

    function unflagQuestion(bytes32 questionId) external onlyAdmin {
        require(flaggedAt[questionId] > 0, "NRO: not flagged");
        flaggedAt[questionId] = 0;
        emit QuestionUnflagged(questionId);
    }

    /**
     * @notice Emergency resolution after the delay has passed since flagging.
     */
    function emergencyResolveQuestion(bytes32 questionId, bool outcome) external onlyAdmin {
        uint256 flagTime = flaggedAt[questionId];
        require(flagTime > 0, "NRO: not flagged");
        require(block.timestamp >= flagTime + EMERGENCY_RESOLUTION_DELAY, "NRO: delay not passed");

        nrAdapter.reportOutcome(questionId, outcome);
        emit QuestionEmergencyResolved(questionId, outcome);
    }
}
