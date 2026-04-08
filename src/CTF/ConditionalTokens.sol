// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ConditionalTokens
 * @notice ERC-1155 based framework for prediction market positions.
 *         Based on Gnosis Conditional Tokens Framework.
 *
 * Positions are ERC-1155 tokens whose IDs are deterministic hashes of:
 *   collateral address + condition ID + outcome partition (indexSet)
 *
 * Lifecycle:
 *   1. Oracle calls prepareCondition()
 *   2. Users call splitPosition() to mint outcome tokens by depositing collateral
 *   3. Oracle calls reportPayouts() to resolve the condition
 *   4. Users call redeemPositions() to claim collateral proportional to payout
 */
contract ConditionalTokens is ERC1155 {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Events
    // =========================================================================

    event ConditionPreparation(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount
    );

    event ConditionResolution(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256[] payoutNumerators
    );

    event PositionSplit(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PositionsMerge(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint256[] indexSets,
        uint256 payout
    );

    // =========================================================================
    // State
    // =========================================================================

    /// @notice payoutNumerators[conditionId][outcomeIndex] — set at resolution
    mapping(bytes32 => uint256[]) public payoutNumerators;

    /// @notice payoutDenominator[conditionId] — non-zero means resolved
    mapping(bytes32 => uint256) public payoutDenominator;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() ERC1155("") {}

    // =========================================================================
    // Condition Management
    // =========================================================================

    /**
     * @notice Prepare a new condition. Only callable by the oracle.
     * @param oracle          Address that will resolve this condition
     * @param questionId      Arbitrary identifier for the question
     * @param outcomeSlotCount Number of outcomes (typically 2 for binary)
     */
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external {
        require(outcomeSlotCount > 1, "CTF: need at least 2 outcomes");
        require(outcomeSlotCount <= 256, "CTF: too many outcomes");

        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);
        require(payoutNumerators[conditionId].length == 0, "CTF: condition already prepared");

        payoutNumerators[conditionId] = new uint256[](outcomeSlotCount);
        emit ConditionPreparation(conditionId, oracle, questionId, outcomeSlotCount);
    }

    /**
     * @notice Report outcome payouts. Called by the oracle after the event resolves.
     * @param questionId Identifies the question being resolved
     * @param payouts    Array of payout numerators; must sum to > 0
     */
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        uint256 outcomeSlotCount = payouts.length;
        require(outcomeSlotCount > 1, "CTF: need at least 2 payouts");

        bytes32 conditionId = getConditionId(msg.sender, questionId, outcomeSlotCount);
        require(payoutNumerators[conditionId].length == outcomeSlotCount, "CTF: condition not prepared");
        require(payoutDenominator[conditionId] == 0, "CTF: already resolved");

        uint256 den = 0;
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            den += payouts[i];
            payoutNumerators[conditionId][i] = payouts[i];
        }
        require(den > 0, "CTF: payout must be positive");

        payoutDenominator[conditionId] = den;
        emit ConditionResolution(conditionId, msg.sender, questionId, outcomeSlotCount, payouts);
    }

    // =========================================================================
    // Position Management
    // =========================================================================

    /**
     * @notice Split a position into outcome tokens.
     *         Transfers `amount` of collateral from the caller and mints
     *         ERC-1155 tokens for each outcome in the partition.
     *
     * @param collateralToken    ERC-20 used as collateral
     * @param parentCollectionId Collection ID of a parent position (0x0 for root)
     * @param conditionId        Condition to split on
     * @param partition          Array of index sets defining the outcome partition
     * @param amount             Amount of collateral to split
     */
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(amount > 0, "CTF: amount must be > 0");
        _validatePartition(conditionId, partition);

        if (parentCollectionId == bytes32(0)) {
            collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            uint256 parentPositionId = getPositionId(collateralToken, parentCollectionId);
            _burn(msg.sender, parentPositionId, amount);
        }

        uint256[] memory positionIds = new uint256[](partition.length);
        uint256[] memory amounts = new uint256[](partition.length);
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, partition[i]);
            positionIds[i] = getPositionId(collateralToken, collectionId);
            amounts[i] = amount;
        }

        _mintBatch(msg.sender, positionIds, amounts, "");
        emit PositionSplit(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    /**
     * @notice Merge outcome tokens back into a single position or collateral.
     *         Burns ERC-1155 tokens for each outcome in the partition and
     *         either transfers collateral back or mints the parent position.
     *
     * @param collateralToken    ERC-20 used as collateral
     * @param parentCollectionId Collection ID of a parent position (0x0 for root)
     * @param conditionId        Condition to merge on
     * @param partition          Array of index sets defining the outcome partition
     * @param amount             Amount to merge
     */
    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(amount > 0, "CTF: amount must be > 0");
        _validatePartition(conditionId, partition);

        uint256[] memory positionIds = new uint256[](partition.length);
        uint256[] memory amounts = new uint256[](partition.length);
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, partition[i]);
            positionIds[i] = getPositionId(collateralToken, collectionId);
            amounts[i] = amount;
        }

        _burnBatch(msg.sender, positionIds, amounts);

        if (parentCollectionId == bytes32(0)) {
            collateralToken.safeTransfer(msg.sender, amount);
        } else {
            uint256 parentPositionId = getPositionId(collateralToken, parentCollectionId);
            _mint(msg.sender, parentPositionId, amount, "");
        }

        emit PositionsMerge(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    /**
     * @notice Redeem positions after condition resolution.
     *         Burns outcome tokens and transfers proportional collateral back.
     *
     * @param collateralToken    ERC-20 used as collateral
     * @param parentCollectionId Collection ID of a parent position (0x0 for root)
     * @param conditionId        Resolved condition
     * @param indexSets          Which outcome positions to redeem
     */
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        uint256 den = payoutDenominator[conditionId];
        require(den > 0, "CTF: condition not resolved");

        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 indexSet = indexSets[i];
            require(indexSet > 0 && indexSet < (1 << outcomeSlotCount), "CTF: invalid index set");

            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, indexSet);
            uint256 positionId = getPositionId(collateralToken, collectionId);
            uint256 balance = balanceOf(msg.sender, positionId);

            if (balance > 0) {
                uint256 positionPayout = 0;
                for (uint256 j = 0; j < outcomeSlotCount; j++) {
                    if (indexSet & (1 << j) != 0) {
                        positionPayout += payoutNumerators[conditionId][j] * balance;
                    }
                }
                totalPayout += positionPayout;
                _burn(msg.sender, positionId, balance);
            }
        }

        if (totalPayout > 0) {
            totalPayout /= den;
            if (parentCollectionId == bytes32(0)) {
                collateralToken.safeTransfer(msg.sender, totalPayout);
            } else {
                uint256 parentPositionId = getPositionId(collateralToken, parentCollectionId);
                _mint(msg.sender, parentPositionId, totalPayout, "");
            }
        }

        emit PayoutRedemption(msg.sender, collateralToken, parentCollectionId, conditionId, indexSets, totalPayout);
    }

    // =========================================================================
    // ID Computation (pure, deterministic)
    // =========================================================================

    /// @notice conditionId = keccak256(oracle, questionId, outcomeSlotCount)
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    /// @notice collectionId = keccak256(parentCollectionId XOR keccak256(conditionId, indexSet))
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        public
        pure
        returns (bytes32)
    {
        return bytes32(uint256(keccak256(abi.encodePacked(conditionId, indexSet))) ^ uint256(parentCollectionId));
    }

    /// @notice positionId = keccak256(collateralToken, collectionId)
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    /// @notice Number of outcome slots for a condition (0 if not prepared)
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return payoutNumerators[conditionId].length;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _validatePartition(bytes32 conditionId, uint256[] calldata partition) internal view {
        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        require(outcomeSlotCount > 0, "CTF: condition not prepared");

        uint256 fullSet = (1 << outcomeSlotCount) - 1;
        uint256 unionIndexSet = 0;

        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            require(indexSet > 0, "CTF: empty index set");
            require(indexSet <= fullSet, "CTF: index set out of range");
            require(unionIndexSet & indexSet == 0, "CTF: partition not disjoint");
            unionIndexSet |= indexSet;
        }

        require(unionIndexSet == fullSet, "CTF: partition incomplete");
    }
}
