// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {Auth} from "../exchange/mixins/Auth.sol";

/**
 * @title OptimisticOracle
 * @notice UMA-style optimistic oracle for resolving prediction market conditions.
 *
 * Resolution flow:
 *   1. An asserter proposes an outcome by posting a bond.
 *   2. During the dispute window, anyone can dispute by posting an equal bond.
 *   3. If undisputed after liveness, the assertion is finalized → CTF condition resolved.
 *   4. If disputed, an admin arbitrates. Winner gets both bonds; loser loses bond.
 *
 * The oracle calls ConditionalTokens.reportPayouts() on finalization.
 */
contract OptimisticOracle is Auth {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    enum AssertionState {
        Pending,   // Proposed, in dispute window
        Disputed,  // Challenged, awaiting arbitration
        Resolved,  // Finalized (reported to CTF)
        Cancelled  // Admin-cancelled
    }

    struct Assertion {
        bytes32 conditionId;
        address asserter;
        address disputer;
        address bondToken;
        uint256 bondAmount;
        uint256 proposedAt;
        uint256 liveness;    // seconds dispute window
        uint256[] payouts;   // proposed outcome payouts
        AssertionState state;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant MIN_LIVENESS = 1 hours;
    uint256 public constant MAX_LIVENESS = 30 days;
    uint256 public constant DEFAULT_LIVENESS = 2 hours;

    // =========================================================================
    // State
    // =========================================================================

    IConditionalTokens public immutable ctf;

    /// @notice assertionId => Assertion
    mapping(bytes32 => Assertion) public assertions;

    /// @notice conditionId => assertionId (only one active assertion per condition)
    mapping(bytes32 => bytes32) public activeAssertion;

    // =========================================================================
    // Events
    // =========================================================================

    event AssertionMade(
        bytes32 indexed assertionId,
        bytes32 indexed conditionId,
        address indexed asserter,
        uint256[] payouts,
        uint256 liveness
    );
    event AssertionDisputed(bytes32 indexed assertionId, address indexed disputer);
    event AssertionResolved(bytes32 indexed assertionId, bytes32 indexed conditionId, uint256[] payouts);
    event AssertionCancelled(bytes32 indexed assertionId);
    event DisputeArbitrated(bytes32 indexed assertionId, bool asserterWon);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _ctf) Auth() {
        require(_ctf != address(0), "Oracle: zero ctf");
        ctf = IConditionalTokens(_ctf);
    }

    // =========================================================================
    // Assertion Lifecycle
    // =========================================================================

    /**
     * @notice Propose an outcome for a CTF condition.
     * @param conditionId  The condition to resolve
     * @param payouts      Proposed payout numerators (must sum > 0)
     * @param bondToken    ERC-20 token for the bond
     * @param bondAmount   Amount to bond (returned if undisputed)
     * @param liveness     Dispute window in seconds
     * @return assertionId Unique ID for this assertion
     */
    function makeAssertion(
        bytes32 conditionId,
        uint256[] calldata payouts,
        address bondToken,
        uint256 bondAmount,
        uint256 liveness
    ) external returns (bytes32 assertionId) {
        require(activeAssertion[conditionId] == bytes32(0), "Oracle: active assertion exists");
        require(ctf.payoutDenominator(conditionId) == 0, "Oracle: already resolved");
        require(liveness >= MIN_LIVENESS && liveness <= MAX_LIVENESS, "Oracle: bad liveness");
        require(bondAmount > 0, "Oracle: zero bond");

        _validatePayouts(payouts);

        assertionId = keccak256(
            abi.encode(conditionId, msg.sender, payouts, bondToken, bondAmount, block.timestamp)
        );
        require(assertions[assertionId].asserter == address(0), "Oracle: assertion exists");

        IERC20(bondToken).safeTransferFrom(msg.sender, address(this), bondAmount);

        assertions[assertionId] = Assertion({
            conditionId: conditionId,
            asserter: msg.sender,
            disputer: address(0),
            bondToken: bondToken,
            bondAmount: bondAmount,
            proposedAt: block.timestamp,
            liveness: liveness,
            payouts: payouts,
            state: AssertionState.Pending
        });
        activeAssertion[conditionId] = assertionId;

        emit AssertionMade(assertionId, conditionId, msg.sender, payouts, liveness);
    }

    /**
     * @notice Dispute a pending assertion within the liveness window.
     *         Disputer must post an equal bond.
     */
    function disputeAssertion(bytes32 assertionId) external {
        Assertion storage a = assertions[assertionId];
        require(a.state == AssertionState.Pending, "Oracle: not pending");
        require(block.timestamp < a.proposedAt + a.liveness, "Oracle: liveness expired");
        require(msg.sender != a.asserter, "Oracle: cannot self-dispute");

        IERC20(a.bondToken).safeTransferFrom(msg.sender, address(this), a.bondAmount);
        a.disputer = msg.sender;
        a.state = AssertionState.Disputed;

        emit AssertionDisputed(assertionId, msg.sender);
    }

    /**
     * @notice Finalize an undisputed assertion after the liveness window.
     *         Anyone can call — no permission required.
     */
    function settleAssertion(bytes32 assertionId) external {
        Assertion storage a = assertions[assertionId];
        require(a.state == AssertionState.Pending, "Oracle: not pending");
        require(block.timestamp >= a.proposedAt + a.liveness, "Oracle: still in liveness");

        a.state = AssertionState.Resolved;
        activeAssertion[a.conditionId] = bytes32(0);

        // Return bond to asserter
        IERC20(a.bondToken).safeTransfer(a.asserter, a.bondAmount);

        // Report to CTF
        ctf.reportPayouts(_getQuestionId(a.conditionId, a.payouts.length), a.payouts);

        emit AssertionResolved(assertionId, a.conditionId, a.payouts);
    }

    /**
     * @notice Arbitrate a disputed assertion. Admin decides winner.
     * @param asserterWon  true = asserter was correct; false = disputer was correct
     */
    function arbitrate(bytes32 assertionId, bool asserterWon, uint256[] calldata correctPayouts)
        external
        onlyAdmin
    {
        Assertion storage a = assertions[assertionId];
        require(a.state == AssertionState.Disputed, "Oracle: not disputed");

        a.state = AssertionState.Resolved;
        activeAssertion[a.conditionId] = bytes32(0);

        // Award both bonds to winner
        address winner = asserterWon ? a.asserter : a.disputer;
        IERC20(a.bondToken).safeTransfer(winner, a.bondAmount * 2);

        uint256[] memory finalPayouts;
        if (asserterWon) {
            finalPayouts = a.payouts;
        } else {
            finalPayouts = correctPayouts;
        }
        ctf.reportPayouts(_getQuestionId(a.conditionId, finalPayouts.length), finalPayouts);

        emit DisputeArbitrated(assertionId, asserterWon);
        emit AssertionResolved(assertionId, a.conditionId, finalPayouts);
    }

    /**
     * @notice Cancel an assertion (admin only). Returns bond to asserter.
     */
    function cancelAssertion(bytes32 assertionId) external onlyAdmin {
        Assertion storage a = assertions[assertionId];
        require(
            a.state == AssertionState.Pending || a.state == AssertionState.Disputed,
            "Oracle: not active"
        );

        a.state = AssertionState.Cancelled;
        activeAssertion[a.conditionId] = bytes32(0);

        IERC20(a.bondToken).safeTransfer(a.asserter, a.bondAmount);
        if (a.disputer != address(0)) {
            IERC20(a.bondToken).safeTransfer(a.disputer, a.bondAmount);
        }

        emit AssertionCancelled(assertionId);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory) {
        return assertions[assertionId];
    }

    function canSettle(bytes32 assertionId) external view returns (bool) {
        Assertion storage a = assertions[assertionId];
        return a.state == AssertionState.Pending
            && block.timestamp >= a.proposedAt + a.liveness;
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _validatePayouts(uint256[] calldata payouts) internal pure {
        require(payouts.length >= 2, "Oracle: need >= 2 payouts");
        uint256 sum = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            sum += payouts[i];
        }
        require(sum > 0, "Oracle: zero payout sum");
    }

    /**
     * @dev The CTF uses keccak256(oracle, questionId, outcomeSlotCount) as conditionId.
     *      We recover the questionId from conditionId by reversing the hash is impossible,
     *      so instead we store it at assertion creation time. For simplicity here we
     *      call reportPayouts with the conditionId's embedded questionId.
     *
     *      In a real deployment, the asserter passes questionId explicitly and we
     *      validate conditionId = ctf.getConditionId(address(this), questionId, slotCount).
     */
    function _getQuestionId(bytes32 conditionId, uint256 /*slotCount*/) internal pure returns (bytes32) {
        // In practice, the assertion stores questionId separately.
        // This stub returns conditionId as a placeholder — override in production.
        return conditionId;
    }
}
