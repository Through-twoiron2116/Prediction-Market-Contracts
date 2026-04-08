// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "../../src/CTF/ConditionalTokens.sol";
import {CTFExchange} from "../../src/exchange/CTFExchange.sol";
import {Order, Side, SignatureType} from "../../src/exchange/mixins/OrderStructs.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/**
 * @notice CTFExchange unit tests.
 *         Uses vm.sign to produce valid EIP-712 signatures for test orders.
 */
contract CTFExchangeTest is Test {
    ConditionalTokens public ctf;
    CTFExchange public exchange;
    ERC20Mock public usdc;

    // Test actors
    uint256 internal makerKey = 0xA11CE;
    uint256 internal takerKey = 0xB0B;
    address internal maker;
    address internal taker;
    address internal operator = makeAddr("operator");
    address internal admin = address(this); // deployer = admin
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal oracle = makeAddr("oracle");

    bytes32 public questionId = keccak256("Will BTC hit $200k in 2025?");
    uint256 public noTokenId;
    uint256 public yesTokenId;
    bytes32 public conditionId;

    uint256 constant AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        maker = vm.addr(makerKey);
        taker = vm.addr(takerKey);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        ctf = new ConditionalTokens();
        exchange = new CTFExchange(address(usdc), address(ctf), feeReceiver);

        // Grant operator role
        exchange.addOperator(operator);

        // Prepare binary condition
        vm.prank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);
        conditionId = ctf.getConditionId(oracle, questionId, 2);

        // Compute token IDs
        bytes32 noCollection = ctf.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 yesCollection = ctf.getCollectionId(bytes32(0), conditionId, 2);
        noTokenId = ctf.getPositionId(IERC20(address(usdc)), noCollection);
        yesTokenId = ctf.getPositionId(IERC20(address(usdc)), yesCollection);

        // Register token pair in exchange
        exchange.registerToken(noTokenId, yesTokenId, conditionId);

        // Fund actors and grant approvals
        usdc.mint(maker, 1000e6);
        usdc.mint(taker, 1000e6);

        vm.prank(maker);
        usdc.approve(address(ctf), type(uint256).max);
        vm.prank(taker);
        usdc.approve(address(ctf), type(uint256).max);

        // Give maker some YES tokens by splitting
        vm.prank(maker);
        ctf.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, _partition(), AMOUNT);

        // Approve exchange for ERC-1155 transfers
        vm.prank(maker);
        ctf.setApprovalForAll(address(exchange), true);
        vm.prank(taker);
        ctf.setApprovalForAll(address(exchange), true);
        vm.prank(maker);
        usdc.approve(address(exchange), type(uint256).max);
        vm.prank(taker);
        usdc.approve(address(exchange), type(uint256).max);
    }

    // =========================================================================
    // Auth tests
    // =========================================================================

    function test_onlyOperatorCanFill() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);
        vm.expectRevert("Auth: not operator");
        exchange.fillOrder(order, AMOUNT);
    }

    function test_adminCanPause() public {
        exchange.pauseTrading();
        assertTrue(exchange.paused());
    }

    function test_pausedBlocksFill() public {
        exchange.pauseTrading();
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);
        vm.prank(operator);
        vm.expectRevert("Pausable: trading paused");
        exchange.fillOrder(order, AMOUNT);
    }

    function test_unpauseRestoresFill() public {
        exchange.pauseTrading();
        exchange.unpauseTrading();
        assertFalse(exchange.paused());
    }

    // =========================================================================
    // Token registration
    // =========================================================================

    function test_registerToken_storesComplement() public {
        assertEq(exchange.getComplement(yesTokenId), noTokenId);
        assertEq(exchange.getComplement(noTokenId), yesTokenId);
    }

    function test_registerToken_revertsOnDuplicate() public {
        vm.expectRevert("Registry: token0 already registered");
        exchange.registerToken(noTokenId, yesTokenId, conditionId);
    }

    function test_registerToken_revertsOnNonAdmin() public {
        vm.prank(maker);
        vm.expectRevert("Auth: not admin");
        exchange.registerToken(noTokenId + 1, yesTokenId + 1, conditionId);
    }

    // =========================================================================
    // Nonce management
    // =========================================================================

    function test_nonceIncrement_invalidatesOrder() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);

        // Maker increments nonce — order should now fail nonce check
        vm.prank(maker);
        exchange.incrementNonce();

        vm.prank(operator);
        vm.expectRevert("Trading: bad nonce");
        exchange.fillOrder(order, AMOUNT);
    }

    // =========================================================================
    // Order cancellation
    // =========================================================================

    function test_cancelOrder() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);

        vm.prank(maker);
        exchange.cancelOrder(order);

        vm.prank(operator);
        vm.expectRevert("Trading: order done");
        exchange.fillOrder(order, AMOUNT);
    }

    function test_cancelOrder_revertsIfNotMaker() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);
        vm.prank(taker);
        vm.expectRevert("Trading: not your order");
        exchange.cancelOrder(order);
    }

    // =========================================================================
    // fillOrder — SELL side (maker sells YES tokens for USDC)
    // =========================================================================

    function test_fillOrder_sell_transfersTokens() public {
        // maker has AMOUNT YES tokens; taker has USDC
        // Maker's SELL order: give AMOUNT YES tokens, want 80 USDC
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerYesBefore = ctf.balanceOf(taker, yesTokenId);

        vm.prank(operator);
        exchange.fillOrder(order, AMOUNT);

        // Maker received USDC (minus fee), taker received YES tokens
        assertGt(usdc.balanceOf(maker), makerUsdcBefore);
        assertEq(ctf.balanceOf(taker, yesTokenId), takerYesBefore + AMOUNT);
    }

    function test_fillOrder_sell_partialFill() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);
        uint256 half = AMOUNT / 2;

        vm.prank(operator);
        exchange.fillOrder(order, half);

        bytes32 orderHash = exchange.hashOrder(order);
        (, uint256 remaining) = exchange.orderStatus(orderHash);
        assertEq(remaining, AMOUNT - half);
    }

    function test_fillOrder_revertsOnOverfill() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);

        vm.prank(operator);
        vm.expectRevert("Trading: overfill");
        exchange.fillOrder(order, AMOUNT + 1);
    }

    function test_fillOrder_revertsOnExpiredOrder() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, block.timestamp - 1);

        vm.prank(operator);
        vm.expectRevert("Trading: expired");
        exchange.fillOrder(order, AMOUNT);
    }

    function test_fillOrder_revertsOnUnregisteredToken() public {
        Order memory order = _makeSellOrder(makerKey, 999, AMOUNT, 80e6, 0);

        vm.prank(operator);
        vm.expectRevert("Trading: unregistered token");
        exchange.fillOrder(order, AMOUNT);
    }

    // =========================================================================
    // Fee collection
    // =========================================================================

    function test_fillOrder_withFee_chargesFeeReceiver() public {
        uint256 feeRateBps = 100; // 1%
        Order memory order = _makeSellOrderWithFee(makerKey, yesTokenId, AMOUNT, 80e6, feeRateBps);

        uint256 feeReceiverBefore = usdc.balanceOf(feeReceiver);

        vm.prank(operator);
        exchange.fillOrder(order, AMOUNT);

        // feeReceiver should have received some USDC
        assertGt(usdc.balanceOf(feeReceiver), feeReceiverBefore);
    }

    function test_fillOrder_feeExceedsMax_reverts() public {
        Order memory order = _makeSellOrderWithFee(makerKey, yesTokenId, AMOUNT, 80e6, 1001);

        vm.prank(operator);
        vm.expectRevert("Trading: fee too high");
        exchange.fillOrder(order, AMOUNT);
    }

    // =========================================================================
    // Signature verification
    // =========================================================================

    function test_fillOrder_revertsOnBadSignature() public {
        Order memory order = _makeSellOrder(makerKey, yesTokenId, AMOUNT, 80e6, 0);
        // Corrupt the signature
        order.signature[0] ^= 0xFF;

        vm.prank(operator);
        vm.expectRevert("Signing: invalid EOA signature");
        exchange.fillOrder(order, AMOUNT);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _partition() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1;
        p[1] = 2;
    }

    function _makeSellOrder(
        uint256 signerKey,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 expiration
    ) internal view returns (Order memory order) {
        order = _makeSellOrderWithFee(signerKey, tokenId, makerAmount, takerAmount, 0);
        order.expiration = expiration;
        // Re-sign with updated expiration
        bytes32 hash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
        order.signature = abi.encodePacked(r, s, v);
    }

    function _makeSellOrderWithFee(
        uint256 signerKey,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 feeRateBps
    ) internal view returns (Order memory order) {
        address signer = vm.addr(signerKey);
        order = Order({
            salt: 1,
            maker: signer,
            signer: signer,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: feeRateBps,
            side: Side.SELL,
            signatureType: SignatureType.EOA,
            signature: ""
        });
        bytes32 hash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
        order.signature = abi.encodePacked(r, s, v);
    }
}
