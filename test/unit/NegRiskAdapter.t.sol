// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "../../src/CTF/ConditionalTokens.sol";
import {NegRiskAdapter} from "../../src/neg-risk/NegRiskAdapter.sol";
import {Vault} from "../../src/neg-risk/Vault.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract NegRiskAdapterTest is Test {
    ConditionalTokens public ctf;
    NegRiskAdapter public adapter;
    Vault public vault;
    ERC20Mock public usdc;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant AMOUNT = 100e6;

    // Market with 3 outcomes
    bytes32 public marketId;
    bytes32[] public questionIds = new bytes32[](3);

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        ctf = new ConditionalTokens();
        vault = new Vault();
        adapter = new NegRiskAdapter(address(ctf), address(usdc), address(vault));

        // Fund alice
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(adapter), type(uint256).max);
        vm.prank(alice);
        ctf.setApprovalForAll(address(adapter), true);

        // Prepare a 3-outcome market (no fee)
        vm.startPrank(address(this));
        marketId = adapter.prepareMarket(0, abi.encode("Which team wins World Cup?"));
        questionIds[0] = adapter.prepareQuestion(marketId, abi.encode("Team A"));
        questionIds[1] = adapter.prepareQuestion(marketId, abi.encode("Team B"));
        questionIds[2] = adapter.prepareQuestion(marketId, abi.encode("Team C"));
        vm.stopPrank();
    }

    // =========================================================================
    // Market preparation
    // =========================================================================

    function test_prepareMarket_storesOracle() public view {
        (address oracle,,,) = adapter.markets(marketId);
        assertEq(oracle, address(this));
    }

    function test_prepareMarket_revertsOnHighFee() public {
        vm.expectRevert("NRA: fee too high");
        adapter.prepareMarket(10_001, abi.encode("bad market"));
    }

    function test_prepareQuestion_incrementsCount() public view {
        (,, uint256 count,) = adapter.markets(marketId);
        assertEq(count, 3);
    }

    function test_prepareQuestion_revertsIfNotOracle() public {
        vm.prank(alice);
        vm.expectRevert("NRA: not market oracle");
        adapter.prepareQuestion(marketId, abi.encode("Team D"));
    }

    // =========================================================================
    // splitPosition
    // =========================================================================

    function test_splitPosition_mintsYesAndNoTokens() public {
        bytes32 qId = questionIds[0];
        uint256 noId = adapter.getPositionId(qId, false);
        uint256 yesId = adapter.getPositionId(qId, true);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        adapter.splitPosition(qId, AMOUNT);

        assertEq(ctf.balanceOf(alice, noId), AMOUNT);
        assertEq(ctf.balanceOf(alice, yesId), AMOUNT);
        assertEq(usdc.balanceOf(alice), usdcBefore - AMOUNT);
    }

    function test_splitPosition_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert("NRA: zero amount");
        adapter.splitPosition(questionIds[0], 0);
    }

    // =========================================================================
    // mergePositions
    // =========================================================================

    function test_mergePositions_returnsCollateral() public {
        bytes32 qId = questionIds[0];

        vm.prank(alice);
        adapter.splitPosition(qId, AMOUNT);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        adapter.mergePositions(qId, AMOUNT);

        assertEq(usdc.balanceOf(alice), usdcBefore + AMOUNT);
    }

    // =========================================================================
    // convertPositions
    // =========================================================================

    function test_convertPositions_twoOutOfThree() public {
        // Split all 3 questions to get NO + YES tokens
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            adapter.splitPosition(questionIds[i], AMOUNT);
        }

        // indexSet = 3 = questions 0 and 1 (k=2)
        // Mechanism: pull k*amount USDC + k NO tokens, split k wcol → k YES + k NO_fresh, burn 2k NO, give k YES to caller
        // Net cost to alice: k*AMOUNT USDC + k NO tokens → k YES tokens (no collateral returned)
        uint256 indexSet = 3;
        uint256 k = 2;
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        adapter.convertPositions(marketId, indexSet, AMOUNT);

        // Alice spent k*AMOUNT USDC for k YES tokens
        assertEq(usdc.balanceOf(alice), usdcBefore - k * AMOUNT);

        // Alice should now hold YES tokens for questions 0 and 1
        assertEq(ctf.balanceOf(alice, adapter.getPositionId(questionIds[0], true)), AMOUNT * 2); // original + new
        assertEq(ctf.balanceOf(alice, adapter.getPositionId(questionIds[1], true)), AMOUNT * 2);
    }

    function test_convertPositions_revertsOnSingleBit() public {
        vm.prank(alice);
        adapter.splitPosition(questionIds[0], AMOUNT);

        vm.prank(alice);
        vm.expectRevert("NRA: need at least 2 positions");
        adapter.convertPositions(marketId, 1, AMOUNT); // only 1 bit set
    }

    function test_convertPositions_revertsOnUnknownMarket() public {
        vm.prank(alice);
        vm.expectRevert("NRA: market not found");
        adapter.convertPositions(keccak256("fake"), 3, AMOUNT);
    }

    // =========================================================================
    // reportOutcome + redeemPositions
    // =========================================================================

    function test_reportOutcome_yesWins() public {
        bytes32 qId = questionIds[0];

        vm.prank(alice);
        adapter.splitPosition(qId, AMOUNT);

        // Report YES (outcome=true)
        adapter.reportOutcome(qId, true);

        (, bool reported, bool outcome) = _getQuestion(qId);
        assertTrue(reported);
        assertTrue(outcome);
    }

    function test_reportOutcome_revertsIfNotOracle() public {
        vm.prank(alice);
        vm.expectRevert("NRA: not oracle");
        adapter.reportOutcome(questionIds[0], true);
    }

    function test_reportOutcome_revertsIfAlreadyReported() public {
        adapter.reportOutcome(questionIds[0], true);
        vm.expectRevert("NRA: already reported");
        adapter.reportOutcome(questionIds[0], false);
    }

    function test_redeemPositions_afterYesWins() public {
        bytes32 qId = questionIds[0];

        vm.prank(alice);
        adapter.splitPosition(qId, AMOUNT);

        // YES wins
        adapter.reportOutcome(qId, true);

        uint256 yesId = adapter.getPositionId(qId, true);
        assertEq(ctf.balanceOf(alice, yesId), AMOUNT);

        uint256 usdcBefore = usdc.balanceOf(alice);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2; // YES indexSet
        vm.prank(alice);
        adapter.redeemPositions(qId, indexSets);

        assertEq(usdc.balanceOf(alice), usdcBefore + AMOUNT);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _getQuestion(bytes32 qId)
        internal
        view
        returns (bytes32 mId, bool reported, bool outcome)
    {
        (mId,, reported, outcome) = adapter.questions(qId);
    }
}
