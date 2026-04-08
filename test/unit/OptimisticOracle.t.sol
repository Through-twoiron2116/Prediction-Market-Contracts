// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "../../src/CTF/ConditionalTokens.sol";
import {OptimisticOracle} from "../../src/oracle/OptimisticOracle.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract OptimisticOracleTest is Test {
    ConditionalTokens public ctf;
    OptimisticOracle public oracle;
    ERC20Mock public bond;

    address public asserter = makeAddr("asserter");
    address public disputer = makeAddr("disputer");
    address public admin = address(this);

    bytes32 public questionId = keccak256("Will X happen?");
    bytes32 public conditionId;

    uint256 constant BOND = 100e18;
    uint256 constant LIVENESS = 2 hours;

    uint256[] internal yesPayouts;
    uint256[] internal noPayouts;

    function setUp() public {
        bond = new ERC20Mock("Bond Token", "BOND", 18);
        ctf = new ConditionalTokens();
        oracle = new OptimisticOracle(address(ctf));

        // Prepare a condition where oracle is the OptimisticOracle
        ctf.prepareCondition(address(oracle), questionId, 2);
        conditionId = ctf.getConditionId(address(oracle), questionId, 2);

        yesPayouts = new uint256[](2);
        yesPayouts[1] = 1;

        noPayouts = new uint256[](2);
        noPayouts[0] = 1;

        bond.mint(asserter, 1000e18);
        bond.mint(disputer, 1000e18);
        vm.prank(asserter);
        bond.approve(address(oracle), type(uint256).max);
        vm.prank(disputer);
        bond.approve(address(oracle), type(uint256).max);
    }

    // =========================================================================
    // makeAssertion
    // =========================================================================

    function test_makeAssertion_locksBond() public {
        uint256 before = bond.balanceOf(asserter);
        bytes32 aId = _assert(yesPayouts);
        assertEq(bond.balanceOf(asserter), before - BOND);
        assertEq(bond.balanceOf(address(oracle)), BOND);

        OptimisticOracle.Assertion memory a = oracle.getAssertion(aId);
        assertEq(a.asserter, asserter);
        assertEq(uint8(a.state), uint8(OptimisticOracle.AssertionState.Pending));
    }

    function test_makeAssertion_revertsOnBadLiveness() public {
        vm.prank(asserter);
        vm.expectRevert("Oracle: bad liveness");
        oracle.makeAssertion(conditionId, yesPayouts, address(bond), BOND, 30 seconds);
    }

    function test_makeAssertion_revertsOnZeroBond() public {
        vm.prank(asserter);
        vm.expectRevert("Oracle: zero bond");
        oracle.makeAssertion(conditionId, yesPayouts, address(bond), 0, LIVENESS);
    }

    function test_makeAssertion_revertsIfActiveExists() public {
        _assert(yesPayouts);
        vm.prank(asserter);
        vm.expectRevert("Oracle: active assertion exists");
        oracle.makeAssertion(conditionId, yesPayouts, address(bond), BOND, LIVENESS);
    }

    // =========================================================================
    // disputeAssertion
    // =========================================================================

    function test_disputeAssertion_locksDisputerBond() public {
        bytes32 aId = _assert(yesPayouts);

        uint256 before = bond.balanceOf(disputer);
        vm.prank(disputer);
        oracle.disputeAssertion(aId);

        assertEq(bond.balanceOf(disputer), before - BOND);
        (,,,,,,,, OptimisticOracle.AssertionState state) = oracle.assertions(aId);
        assertEq(uint8(state), uint8(OptimisticOracle.AssertionState.Disputed));
    }

    function test_disputeAssertion_revertsAfterLiveness() public {
        bytes32 aId = _assert(yesPayouts);
        vm.warp(block.timestamp + LIVENESS + 1);

        vm.prank(disputer);
        vm.expectRevert("Oracle: liveness expired");
        oracle.disputeAssertion(aId);
    }

    function test_disputeAssertion_revertsIfSelfDispute() public {
        bytes32 aId = _assert(yesPayouts);
        vm.prank(asserter);
        vm.expectRevert("Oracle: cannot self-dispute");
        oracle.disputeAssertion(aId);
    }

    // =========================================================================
    // settleAssertion
    // =========================================================================

    function test_settleAssertion_undisputed_resolvesCondition() public {
        bytes32 aId = _assert(yesPayouts);

        vm.warp(block.timestamp + LIVENESS + 1);

        uint256 asserterBefore = bond.balanceOf(asserter);

        // Anyone can settle
        oracle.settleAssertion(aId);

        // Bond returned
        assertEq(bond.balanceOf(asserter), asserterBefore + BOND);

        // CTF condition should be resolved (YES wins)
        assertGt(ctf.payoutDenominator(conditionId), 0);
        assertEq(ctf.payoutNumerators(conditionId, 1), 1);
    }

    function test_settleAssertion_revertsBeforeLiveness() public {
        bytes32 aId = _assert(yesPayouts);

        vm.expectRevert("Oracle: still in liveness");
        oracle.settleAssertion(aId);
    }

    function test_settleAssertion_revertsIfDisputed() public {
        bytes32 aId = _assert(yesPayouts);
        vm.prank(disputer);
        oracle.disputeAssertion(aId);

        vm.warp(block.timestamp + LIVENESS + 1);
        vm.expectRevert("Oracle: not pending");
        oracle.settleAssertion(aId);
    }

    // =========================================================================
    // arbitrate
    // =========================================================================

    function test_arbitrate_asserterWins_resolves() public {
        bytes32 aId = _assert(yesPayouts);
        vm.prank(disputer);
        oracle.disputeAssertion(aId);

        uint256 asserterBefore = bond.balanceOf(asserter);

        // Admin rules in favor of asserter
        oracle.arbitrate(aId, true, new uint256[](0));

        // Asserter gets both bonds
        assertEq(bond.balanceOf(asserter), asserterBefore + BOND * 2);

        // CTF resolved with asserter's payouts
        assertGt(ctf.payoutDenominator(conditionId), 0);
    }

    function test_arbitrate_disputerWins_resolvesWithCorrectPayouts() public {
        bytes32 aId = _assert(yesPayouts); // asserter says YES wins
        vm.prank(disputer);
        oracle.disputeAssertion(aId);

        uint256 disputerBefore = bond.balanceOf(disputer);

        // Admin rules for disputer (NO actually won)
        oracle.arbitrate(aId, false, noPayouts);

        assertEq(bond.balanceOf(disputer), disputerBefore + BOND * 2);
        // NO wins
        assertEq(ctf.payoutNumerators(conditionId, 0), 1);
        assertEq(ctf.payoutNumerators(conditionId, 1), 0);
    }

    function test_arbitrate_revertsIfNotDisputed() public {
        bytes32 aId = _assert(yesPayouts);
        vm.expectRevert("Oracle: not disputed");
        oracle.arbitrate(aId, true, new uint256[](0));
    }

    function test_arbitrate_revertsIfNotAdmin() public {
        bytes32 aId = _assert(yesPayouts);
        vm.prank(disputer);
        oracle.disputeAssertion(aId);

        vm.prank(asserter);
        vm.expectRevert("Auth: not admin");
        oracle.arbitrate(aId, true, new uint256[](0));
    }

    // =========================================================================
    // cancelAssertion
    // =========================================================================

    function test_cancelAssertion_returnsBond() public {
        bytes32 aId = _assert(yesPayouts);
        uint256 before = bond.balanceOf(asserter);

        oracle.cancelAssertion(aId);

        assertEq(bond.balanceOf(asserter), before + BOND);
        (,,,,,,,, OptimisticOracle.AssertionState state) = oracle.assertions(aId);
        assertEq(uint8(state), uint8(OptimisticOracle.AssertionState.Cancelled));
    }

    function test_cancelAssertion_withDisputer_returnsBothBonds() public {
        bytes32 aId = _assert(yesPayouts);
        vm.prank(disputer);
        oracle.disputeAssertion(aId);

        uint256 aBefore = bond.balanceOf(asserter);
        uint256 dBefore = bond.balanceOf(disputer);

        oracle.cancelAssertion(aId);

        assertEq(bond.balanceOf(asserter), aBefore + BOND);
        assertEq(bond.balanceOf(disputer), dBefore + BOND);
    }

    function test_cancelAssertion_revertsIfNotAdmin() public {
        bytes32 aId = _assert(yesPayouts);
        vm.prank(asserter);
        vm.expectRevert("Auth: not admin");
        oracle.cancelAssertion(aId);
    }

    // =========================================================================
    // canSettle view
    // =========================================================================

    function test_canSettle_falseBeforeLiveness() public {
        bytes32 aId = _assert(yesPayouts);
        assertFalse(oracle.canSettle(aId));
    }

    function test_canSettle_trueAfterLiveness() public {
        bytes32 aId = _assert(yesPayouts);
        vm.warp(block.timestamp + LIVENESS + 1);
        assertTrue(oracle.canSettle(aId));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _assert(uint256[] memory payouts) internal returns (bytes32) {
        vm.prank(asserter);
        return oracle.makeAssertion(conditionId, payouts, address(bond), BOND, LIVENESS);
    }
}
