// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {WrappedCollateral} from "./WrappedCollateral.sol";

/**
 * @title NegRiskAdapter
 * @notice Enables conversion of NO token positions across mutually-exclusive
 *         binary markets into YES tokens + collateral.
 *
 * Concept — "Neg Risk":
 *   In a multi-outcome categorical market (e.g., "Which team wins?"), holding
 *   all NO positions is equivalent to holding collateral minus one YES position.
 *   This contract lets users convert a set of NO tokens into the corresponding
 *   YES tokens + collateral, unwinding redundant exposure.
 *
 * Market structure:
 *   - A "market" groups N binary questions that are mutually exclusive.
 *   - Each question has a YES token and a NO token (CTF positions).
 *   - The adapter wraps USDC in WrappedCollateral before splitting CTF positions.
 *
 * Key invariant:
 *   Converting K out of N NO positions yields (K-1) * amount collateral + YES tokens.
 */
contract NegRiskAdapter is ERC1155Holder {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant FEE_DENOMINATOR = 10_000;
    /// @dev Burn address for NO tokens that can never be redeemed
    address public constant NO_TOKEN_BURN_ADDRESS = address(0xdEaD);

    // =========================================================================
    // Immutables
    // =========================================================================

    IConditionalTokens public immutable ctf;
    IERC20 public immutable col; // underlying collateral (USDC)
    WrappedCollateral public immutable wcol; // wrapped collateral (used in CTF)
    address public immutable vault; // fee recipient

    // =========================================================================
    // Market State
    // =========================================================================

    struct MarketData {
        address oracle;
        uint256 feeBips;
        uint256 questionCount;
        bool resolved;
    }

    struct QuestionData {
        bytes32 marketId;
        uint256 index; // position within the market's question list
        bool reported;
        bool outcome; // true = YES won
    }

    mapping(bytes32 => MarketData) public markets;
    mapping(bytes32 => QuestionData) public questions;
    /// @notice marketId => list of questionIds in order
    mapping(bytes32 => bytes32[]) public marketQuestions;

    // =========================================================================
    // Events
    // =========================================================================

    event MarketPrepared(
        bytes32 indexed marketId, address indexed oracle, uint256 feeBips, bytes data
    );
    event QuestionPrepared(
        bytes32 indexed marketId, bytes32 indexed questionId, uint256 index, bytes data
    );
    event OutcomeReported(
        bytes32 indexed marketId, bytes32 indexed questionId, bool outcome
    );
    event PositionsConverted(
        address indexed stakeholder,
        bytes32 indexed marketId,
        uint256 indexed indexSet,
        uint256 amount
    );

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _ctf, address _collateral, address _vault) {
        require(_ctf != address(0) && _collateral != address(0) && _vault != address(0), "NRA: zero address");
        ctf = IConditionalTokens(_ctf);
        col = IERC20(_collateral);
        vault = _vault;

        wcol = new WrappedCollateral(
            _collateral,
            "Wrapped Collateral",
            "WCOL"
        );

        // Approve CTF to pull wrapped collateral for splitPosition
        IERC20(address(wcol)).forceApprove(_ctf, type(uint256).max);
    }

    // =========================================================================
    // Market Administration
    // =========================================================================

    /**
     * @notice Prepare a new categorical market.
     * @param feeBips Fee taken on each position conversion (in basis points)
     * @param data    Arbitrary metadata (e.g., IPFS hash of the question)
     * @return marketId Deterministic ID for this market
     */
    function prepareMarket(uint256 feeBips, bytes calldata data)
        external
        returns (bytes32 marketId)
    {
        require(feeBips <= FEE_DENOMINATOR, "NRA: fee too high");
        marketId = keccak256(abi.encode(msg.sender, feeBips, data, block.timestamp));
        require(markets[marketId].oracle == address(0), "NRA: market exists");

        markets[marketId] = MarketData({
            oracle: msg.sender,
            feeBips: feeBips,
            questionCount: 0,
            resolved: false
        });

        emit MarketPrepared(marketId, msg.sender, feeBips, data);
    }

    /**
     * @notice Add a binary question to an existing market.
     * @param marketId Target market
     * @param data     Question metadata
     * @return questionId CTF condition ID for this question
     */
    function prepareQuestion(bytes32 marketId, bytes calldata data)
        external
        returns (bytes32 questionId)
    {
        MarketData storage market = markets[marketId];
        require(market.oracle == msg.sender, "NRA: not market oracle");
        require(!market.resolved, "NRA: market resolved");

        uint256 index = market.questionCount;
        questionId = keccak256(abi.encode(marketId, index, data));

        // Prepare binary condition in CTF (2 outcomes: NO=0, YES=1)
        ctf.prepareCondition(address(this), questionId, 2);

        questions[questionId] = QuestionData({
            marketId: marketId,
            index: index,
            reported: false,
            outcome: false
        });
        marketQuestions[marketId].push(questionId);
        market.questionCount++;

        emit QuestionPrepared(marketId, questionId, index, data);
    }

    /**
     * @notice Report the binary outcome for a question. Only callable by the market oracle.
     * @param questionId The question to resolve
     * @param outcome    true = YES won, false = NO won
     */
    function reportOutcome(bytes32 questionId, bool outcome) external {
        QuestionData storage question = questions[questionId];
        MarketData storage market = markets[question.marketId];

        require(market.oracle == msg.sender, "NRA: not oracle");
        require(!question.reported, "NRA: already reported");

        question.reported = true;
        question.outcome = outcome;

        // Report to CTF: payouts[0]=NO, payouts[1]=YES
        uint256[] memory payouts = new uint256[](2);
        payouts[outcome ? 1 : 0] = 1;
        ctf.reportPayouts(questionId, payouts);

        emit OutcomeReported(question.marketId, questionId, outcome);
    }

    // =========================================================================
    // Position Management
    // =========================================================================

    /**
     * @notice Split collateral into YES+NO position pairs for a question.
     * @param questionId CTF question ID
     * @param amount     Amount of collateral to split
     */
    function splitPosition(bytes32 questionId, uint256 amount) external {
        require(amount > 0, "NRA: zero amount");
        bytes32 conditionId = getConditionId(questionId);

        // Wrap collateral
        col.safeTransferFrom(msg.sender, address(this), amount);
        col.forceApprove(address(wcol), amount);
        wcol.wrap(address(this), address(this), amount);

        // Split into YES (indexSet=2) and NO (indexSet=1) tokens
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1; // NO
        partition[1] = 2; // YES

        ctf.splitPosition(IERC20(address(wcol)), bytes32(0), conditionId, partition, amount);

        // Transfer tokens to caller
        uint256 noTokenId = getPositionId(questionId, false);
        uint256 yesTokenId = getPositionId(questionId, true);
        IERC1155(address(ctf)).safeTransferFrom(address(this), msg.sender, noTokenId, amount, "");
        IERC1155(address(ctf)).safeTransferFrom(address(this), msg.sender, yesTokenId, amount, "");
    }

    /**
     * @notice Merge YES+NO position pairs back into collateral.
     * @param questionId CTF question ID
     * @param amount     Amount to merge
     */
    function mergePositions(bytes32 questionId, uint256 amount) external {
        require(amount > 0, "NRA: zero amount");
        bytes32 conditionId = getConditionId(questionId);

        uint256 noTokenId = getPositionId(questionId, false);
        uint256 yesTokenId = getPositionId(questionId, true);

        // Pull tokens from caller
        IERC1155(address(ctf)).safeTransferFrom(msg.sender, address(this), noTokenId, amount, "");
        IERC1155(address(ctf)).safeTransferFrom(msg.sender, address(this), yesTokenId, amount, "");

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        ctf.mergePositions(IERC20(address(wcol)), bytes32(0), conditionId, partition, amount);

        // Unwrap and return collateral
        wcol.unwrap(msg.sender, amount);
    }

    /**
     * @notice Convert NO positions from multiple questions in a market into
     *         YES tokens + collateral.
     *
     *         Conversion math (for K questions in indexSet):
     *           collateral out = (K - 1) * amount
     *           YES tokens out = 1 per question in indexSet (at `amount` each)
     *
     * @param marketId Market containing the questions
     * @param indexSet Bitmask of question indices to convert (must have >= 2 bits set)
     * @param amount   Amount per NO position
     */
    function convertPositions(bytes32 marketId, uint256 indexSet, uint256 amount) external {
        MarketData storage market = markets[marketId];
        require(market.oracle != address(0), "NRA: market not found");
        require(amount > 0, "NRA: zero amount");

        uint256 questionCount = market.questionCount;
        require(indexSet > 0 && indexSet < (1 << questionCount), "NRA: bad indexSet");

        // Count questions in indexSet
        uint256 k = _popcount(indexSet);
        require(k >= 2, "NRA: need at least 2 positions");

        bytes32[] storage qIds = marketQuestions[marketId];

        // Pull NO tokens from caller and split into YES+NO pairs
        for (uint256 i = 0; i < questionCount; i++) {
            if (indexSet & (1 << i) != 0) {
                bytes32 qId = qIds[i];
                uint256 noTokenId = getPositionId(qId, false);
                IERC1155(address(ctf)).safeTransferFrom(msg.sender, address(this), noTokenId, amount, "");

                // Split 1 collateral to get 1 YES + 1 NO
                bytes32 conditionId = getConditionId(qId);
                col.safeTransferFrom(msg.sender, address(this), amount);
                col.forceApprove(address(wcol), amount);
                wcol.wrap(address(this), address(this), amount);
                uint256[] memory partition = new uint256[](2);
                partition[0] = 1;
                partition[1] = 2;
                ctf.splitPosition(IERC20(address(wcol)), bytes32(0), conditionId, partition, amount);

                // Burn the NO token (both the one from caller and the freshly minted one)
                uint256 freshNoId = getPositionId(qId, false);
                IERC1155(address(ctf)).safeTransferFrom(address(this), NO_TOKEN_BURN_ADDRESS, freshNoId, amount, "");
                IERC1155(address(ctf)).safeTransferFrom(address(this), NO_TOKEN_BURN_ADDRESS, noTokenId, amount, "");

                // Transfer YES token to caller
                uint256 yesTokenId = getPositionId(qId, true);
                IERC1155(address(ctf)).safeTransferFrom(address(this), msg.sender, yesTokenId, amount, "");
            }
        }

        // Fee on the 1-unit net cost (caller provided k collateral, k wcol consumed in splits)
        uint256 fee = (amount * market.feeBips) / FEE_DENOMINATOR;
        if (fee > 0) {
            col.safeTransfer(vault, fee);
        }

        emit PositionsConverted(msg.sender, marketId, indexSet, amount);
    }

    /**
     * @notice Redeem resolved positions through the CTF.
     * @param questionId  The resolved question
     * @param indexSets   Which outcome positions to redeem
     */
    function redeemPositions(bytes32 questionId, uint256[] calldata indexSets) external {
        bytes32 conditionId = getConditionId(questionId);

        // Pull the caller's position tokens into this contract so CTF can burn them
        for (uint256 i = 0; i < indexSets.length; i++) {
            bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSets[i]);
            uint256 positionId = ctf.getPositionId(IERC20(address(wcol)), collectionId);
            uint256 bal = IERC1155(address(ctf)).balanceOf(msg.sender, positionId);
            if (bal > 0) {
                IERC1155(address(ctf)).safeTransferFrom(msg.sender, address(this), positionId, bal, "");
            }
        }

        ctf.redeemPositions(IERC20(address(wcol)), bytes32(0), conditionId, indexSets);

        // Unwrap any wcol received and forward as raw collateral to caller
        uint256 wcolBal = wcol.balanceOf(address(this));
        if (wcolBal > 0) {
            wcol.unwrap(msg.sender, wcolBal);
        }
    }

    // =========================================================================
    // ID Helpers
    // =========================================================================

    /// @notice conditionId for a question (adapter is the oracle)
    function getConditionId(bytes32 questionId) public view returns (bytes32) {
        return ctf.getConditionId(address(this), questionId, 2);
    }

    /// @notice ERC-1155 position ID in the CTF
    function getPositionId(bytes32 questionId, bool isYes) public view returns (uint256) {
        bytes32 conditionId = getConditionId(questionId);
        uint256 indexSet = isYes ? 2 : 1;
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        return ctf.getPositionId(IERC20(address(wcol)), collectionId);
    }

    // =========================================================================
    // ERC-1155 Proxy Views
    // =========================================================================

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return IERC1155(address(ctf)).balanceOf(account, id);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _popcount(uint256 x) internal pure returns (uint256 count) {
        while (x != 0) {
            count += x & 1;
            x >>= 1;
        }
    }
}
