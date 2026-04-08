// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ConditionalTokens} from "../../src/CTF/ConditionalTokens.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ConditionalTokensTest is Test {
    ConditionalTokens public ctf;
    ERC20Mock public usdc;

    address public oracle = makeAddr("oracle");
    address public alice = makeAddr("alice");

    bytes32 public questionId = keccak256("Will ETH reach $10k by end of 2025?");
    uint256 public constant AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        ctf = new ConditionalTokens();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        usdc.mint(alice, 1000e6);
        vm.prank(alice);
        usdc.approve(address(ctf), type(uint256).max);
    }

    // =========================================================================
    // prepareCondition
    // =========================================================================

    function test_prepareCondition() public {
        vm.prank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);

        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        assertEq(ctf.getOutcomeSlotCount(conditionId), 2);
    }

    function test_prepareCondition_revertsIfAlreadyPrepared() public {
        vm.startPrank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);
        vm.expectRevert("CTF: condition already prepared");
        ctf.prepareCondition(oracle, questionId, 2);
        vm.stopPrank();
    }

    function test_prepareCondition_revertsOnSingleOutcome() public {
        vm.prank(oracle);
        vm.expectRevert("CTF: need at least 2 outcomes");
        ctf.prepareCondition(oracle, questionId, 1);
    }

    // =========================================================================
    // splitPosition
    // =========================================================================

    function test_splitPosition_mintsOutcomeTokens() public {
        _prepareAndSplit();

        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        uint256 noTokenId = _positionId(conditionId, 1);
        uint256 yesTokenId = _positionId(conditionId, 2);

        assertEq(ctf.balanceOf(alice, noTokenId), AMOUNT);
        assertEq(ctf.balanceOf(alice, yesTokenId), AMOUNT);
        assertEq(usdc.balanceOf(address(ctf)), AMOUNT);
    }

    function test_splitPosition_revertsOnUnpreparedCondition() public {
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(alice);
        vm.expectRevert("CTF: condition not prepared");
        ctf.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
    }

    // =========================================================================
    // mergePositions
    // =========================================================================

    function test_mergePositions_returnsCollateral() public {
        _prepareAndSplit();

        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        uint256 noTokenId = _positionId(conditionId, 1);
        uint256 yesTokenId = _positionId(conditionId, 2);

        vm.startPrank(alice);
        ctf.setApprovalForAll(address(ctf), true);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ctf.mergePositions(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
        vm.stopPrank();

        assertEq(ctf.balanceOf(alice, noTokenId), 0);
        assertEq(ctf.balanceOf(alice, yesTokenId), 0);
        assertEq(usdc.balanceOf(alice), 1000e6); // all collateral returned
    }

    // =========================================================================
    // reportPayouts + redeemPositions
    // =========================================================================

    function test_redeemPositions_yesWins() public {
        _prepareAndSplit();
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);

        // YES (index 1) wins
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0; // NO loses
        payouts[1] = 1; // YES wins
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);

        assertEq(ctf.payoutDenominator(conditionId), 1);

        // Redeem YES position
        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2; // YES indexSet

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ctf.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, indexSets);

        assertEq(usdc.balanceOf(alice) - balBefore, AMOUNT);
    }

    function test_redeemPositions_noWins() public {
        _prepareAndSplit();
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // NO wins
        payouts[1] = 0;
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1; // NO indexSet

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ctf.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, indexSets);

        assertEq(usdc.balanceOf(alice) - balBefore, AMOUNT);
    }

    function test_reportPayouts_revertsIfNotOracle() public {
        vm.prank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);

        uint256[] memory payouts = new uint256[](2);
        payouts[1] = 1;

        vm.prank(alice); // alice is not the oracle
        vm.expectRevert("CTF: condition not prepared");
        ctf.reportPayouts(questionId, payouts);
    }

    function test_reportPayouts_revertsIfAlreadyResolved() public {
        _prepareAndSplit();
        uint256[] memory payouts = new uint256[](2);
        payouts[1] = 1;
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);

        vm.prank(oracle);
        vm.expectRevert("CTF: already resolved");
        ctf.reportPayouts(questionId, payouts);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _prepareAndSplit() internal {
        vm.prank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);

        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(alice);
        ctf.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
    }

    function _positionId(bytes32 conditionId, uint256 indexSet) internal view returns (uint256) {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        return ctf.getPositionId(IERC20(address(usdc)), collectionId);
    }
}
