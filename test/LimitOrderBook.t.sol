// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {LimitOrderBook} from "../contracts/core/LimitOrderBook.sol";
import {CompactEncoding} from "../contracts/libraries/CompactEncoding.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title LimitOrderBook Test Suite
/// @notice Comprehensive tests for the LimitOrderBook contract
contract LimitOrderBookTest is Test {
    LimitOrderBook public orderBook;
    ERC20Mock public baseToken;
    ERC20Mock public quoteToken;
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public feeRecipient = address(0x4);
    
    uint128 constant MIN_ORDER_SIZE = 1e15; // 0.001 tokens
    uint128 constant MAX_ORDER_SIZE = 1000e18; // 1000 tokens
    uint24 constant FEE_BPS = 30; // 0.3%
    
    event OrderPlaced(
        bytes32 indexed orderHash,
        address indexed maker,
        uint8 side,
        uint128 amount,
        uint128 limitPrice,
        uint64 expiry
    );
    
    event OrderExecuted(
        bytes32 indexed orderHash,
        address indexed taker,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 feeAmount,
        bool fullyFilled
    );
    
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
    
    function setUp() public {
        // Deploy mock tokens
        baseToken = new ERC20Mock();
        quoteToken = new ERC20Mock();
        
        // Deploy order book
        orderBook = new LimitOrderBook(
            address(baseToken),
            address(quoteToken),
            MIN_ORDER_SIZE,
            MAX_ORDER_SIZE,
            FEE_BPS,
            feeRecipient
        );
        
        // Mint tokens to test users
        baseToken.mint(alice, 10000e18);
        baseToken.mint(bob, 10000e18);
        baseToken.mint(charlie, 10000e18);
        
        quoteToken.mint(alice, 10000e18);
        quoteToken.mint(bob, 10000e18);
        quoteToken.mint(charlie, 10000e18);
        
        // Approve order book
        vm.prank(alice);
        baseToken.approve(address(orderBook), type(uint256).max);
        vm.prank(alice);
        quoteToken.approve(address(orderBook), type(uint256).max);
        
        vm.prank(bob);
        baseToken.approve(address(orderBook), type(uint256).max);
        vm.prank(bob);
        quoteToken.approve(address(orderBook), type(uint256).max);
        
        vm.prank(charlie);
        baseToken.approve(address(orderBook), type(uint256).max);
        vm.prank(charlie);
        quoteToken.approve(address(orderBook), type(uint256).max);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ORDER PLACEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testPlaceOrder() public {
        vm.startPrank(alice);
        
        uint128 amount = 1e18;
        uint128 limitPrice = 2000e18;
        uint8 side = 1; // sell
        uint64 expiry = uint64(block.timestamp + 1 days);
        
        bytes32 orderHash = orderBook.placeOrder(
            amount,
            limitPrice,
            side,
            expiry,
            true
        );
        
        // Verify order status
        LimitOrderBook.OrderStatus memory status = orderBook.getOrderStatus(orderHash);
        assertTrue(status.exists);
        assertFalse(status.cancelled);
        assertEq(status.filledAmount, 0);
        assertEq(status.totalAmount, amount);
        assertEq(status.maker, alice);
        
        // Verify tokens were locked
        assertEq(baseToken.balanceOf(address(orderBook)), amount);
        
        vm.stopPrank();
    }
    
    function testPlaceOrderCompact() public {
        vm.startPrank(alice);
        
        uint64 nonce = orderBook.getUserNonce(alice);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint128 amount = 1e18;
        uint128 limitPrice = 2000e18;
        uint8 side = 1; // sell
        
        // Pack order using CompactEncoding
        bytes memory packedOrder = CompactEncoding.packOrder(
            nonce,
            expiry,
            amount,
            limitPrice,
            side
        );
        
        bytes32 orderHash = orderBook.placeOrderCompact(packedOrder, true);
        
        // Verify order was placed
        LimitOrderBook.OrderStatus memory status = orderBook.getOrderStatus(orderHash);
        assertTrue(status.exists);
        assertEq(status.totalAmount, amount);
        
        vm.stopPrank();
    }
    
    function testPlaceOrderRevertsIfTooSmall() public {
        vm.startPrank(alice);
        
        vm.expectRevert(LimitOrderBook.OrderTooSmall.selector);
        orderBook.placeOrder(
            MIN_ORDER_SIZE - 1,
            2000e18,
            1,
            uint64(block.timestamp + 1 days),
            true
        );
        
        vm.stopPrank();
    }
    
    function testPlaceOrderRevertsIfTooLarge() public {
        vm.startPrank(alice);
        
        vm.expectRevert(LimitOrderBook.OrderTooLarge.selector);
        orderBook.placeOrder(
            MAX_ORDER_SIZE + 1,
            2000e18,
            1,
            uint64(block.timestamp + 1 days),
            true
        );
        
        vm.stopPrank();
    }
    
    function testPlaceOrderRevertsIfExpired() public {
        vm.startPrank(alice);
        
        vm.expectRevert(LimitOrderBook.OrderExpired.selector);
        orderBook.placeOrder(
            1e18,
            2000e18,
            1,
            uint64(block.timestamp - 1),
            true
        );
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                        ORDER EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testExecuteOrder() public {
        // Alice places a sell order
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            1e18,
            2000e18,
            1, // sell
            uint64(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();
        
        // Bob executes the order
        vm.startPrank(bob);
        
        uint256 bobQuoteBefore = quoteToken.balanceOf(bob);
        uint256 bobBaseBefore = baseToken.balanceOf(bob);
        
        LimitOrderBook.ExecutionResult memory result = orderBook.executeOrder(
            orderHash,
            1e18
        );
        
        // Verify execution result
        assertEq(result.baseAmount, 1e18);
        assertEq(result.quoteAmount, 2000e18);
        assertTrue(result.fullyFilled);
        
        // Verify token transfers
        uint256 feeAmount = (uint256(1e18) * uint256(FEE_BPS)) / 10000;
        assertEq(baseToken.balanceOf(bob), bobBaseBefore + 1e18 - feeAmount);
        assertEq(quoteToken.balanceOf(bob), bobQuoteBefore - 2000e18);
        assertEq(quoteToken.balanceOf(alice), 10000e18 + 2000e18);
        
        vm.stopPrank();
    }
    
    function testExecutePartialFill() public {
        // Alice places a sell order
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            2e18,
            2000e18,
            1, // sell
            uint64(block.timestamp + 1 days),
            true // partial fills allowed
        );
        vm.stopPrank();
        
        // Bob partially fills the order
        vm.startPrank(bob);
        LimitOrderBook.ExecutionResult memory result = orderBook.executeOrder(
            orderHash,
            1e18
        );
        
        assertEq(result.baseAmount, 1e18);
        assertFalse(result.fullyFilled);
        
        // Verify order status
        LimitOrderBook.OrderStatus memory status = orderBook.getOrderStatus(orderHash);
        assertEq(status.filledAmount, 1e18);
        assertEq(status.totalAmount, 2e18);
        
        vm.stopPrank();
    }
    
    function testExecuteOrderRevertsIfPartialFillNotAllowed() public {
        // Alice places a sell order without partial fills
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            2e18,
            2000e18,
            1, // sell
            uint64(block.timestamp + 1 days),
            false // partial fills NOT allowed
        );
        vm.stopPrank();
        
        // Bob tries to partially fill
        vm.startPrank(bob);
        vm.expectRevert(LimitOrderBook.PartialFillNotAllowed.selector);
        orderBook.executeOrder(orderHash, 1e18);
        vm.stopPrank();
    }
    
    function testBatchExecuteOrders() public {
        // Alice places multiple sell orders
        vm.startPrank(alice);
        bytes32[] memory orderHashes = new bytes32[](3);
        orderHashes[0] = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        orderHashes[1] = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        orderHashes[2] = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        vm.stopPrank();
        
        // Bob batch executes all orders
        vm.startPrank(bob);
        uint128[] memory amounts = new uint128[](3);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        amounts[2] = 1e18;
        
        LimitOrderBook.ExecutionResult[] memory results = orderBook.batchExecuteOrders(
            orderHashes,
            amounts
        );
        
        assertEq(results.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(results[i].fullyFilled);
            assertEq(results[i].baseAmount, 1e18);
        }
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                        ORDER CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCancelOrder() public {
        // Alice places an order
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            1e18,
            2000e18,
            1, // sell
            uint64(block.timestamp + 1 days),
            true
        );
        
        uint256 aliceBaseBefore = baseToken.balanceOf(alice);
        
        // Cancel the order
        orderBook.cancelOrder(orderHash);
        
        // Verify order is cancelled
        LimitOrderBook.OrderStatus memory status = orderBook.getOrderStatus(orderHash);
        assertTrue(status.cancelled);
        
        // Verify tokens were refunded
        assertEq(baseToken.balanceOf(alice), aliceBaseBefore + 1e18);
        
        vm.stopPrank();
    }
    
    function testCancelOrderRevertsIfNotMaker() public {
        // Alice places an order
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            1e18,
            2000e18,
            1,
            uint64(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();
        
        // Bob tries to cancel
        vm.startPrank(bob);
        vm.expectRevert(LimitOrderBook.NotOrderMaker.selector);
        orderBook.cancelOrder(orderHash);
        vm.stopPrank();
    }
    
    function testBatchCancelOrders() public {
        // Alice places multiple orders
        vm.startPrank(alice);
        bytes32[] memory orderHashes = new bytes32[](3);
        orderHashes[0] = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        orderHashes[1] = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        orderHashes[2] = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        
        // Batch cancel
        orderBook.batchCancelOrders(orderHashes);
        
        // Verify all cancelled
        for (uint256 i = 0; i < 3; i++) {
            LimitOrderBook.OrderStatus memory status = orderBook.getOrderStatus(orderHashes[i]);
            assertTrue(status.cancelled);
        }
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                        COMPACT ENCODING TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCompactEncodingPackUnpack() public view {
        uint64 nonce = 123;
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint128 amount = 1e18;
        uint128 limitPrice = 2000e18;
        uint8 side = 1;
        
        // Pack
        bytes memory packed = CompactEncoding.packOrder(
            nonce,
            expiry,
            amount,
            limitPrice,
            side
        );
        
        // Verify packed size
        assertEq(packed.length, 49);
        
        // Note: Unpacking requires calldata, which is tested via placeOrderCompact
        // The packing/unpacking is implicitly tested in testPlaceOrderCompact
    }
    
    function testCompactEncodingPriceCompression() public {
        uint128 price = 2000e18;
        uint8 decimals = 6;
        
        // Compress
        uint64 compressed = CompactEncoding.compressPrice(price, decimals);
        
        // Decompress
        uint128 decompressed = CompactEncoding.decompressPrice(compressed, decimals);
        
        // Verify (with acceptable precision loss)
        assertApproxEqRel(decompressed, price, 1e12); // 0.0001% tolerance
    }
    
    function testCompactEncodingPriceRange() public {
        uint64 minPrice = 1000e6;
        uint64 maxPrice = 2000e6;
        
        // Encode
        uint128 encoded = CompactEncoding.encodePriceRange(minPrice, maxPrice);
        
        // Decode
        (uint64 decodedMin, uint64 decodedMax) = CompactEncoding.decodePriceRange(encoded);
        
        assertEq(decodedMin, minPrice);
        assertEq(decodedMax, maxPrice);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testUpdateParameters() public {
        orderBook.updateParameters(1e16, 2000e18, 50);
        
        assertEq(orderBook.minOrderSize(), 1e16);
        assertEq(orderBook.maxOrderSize(), 2000e18);
        assertEq(orderBook.feeBps(), 50);
    }
    
    function testCollectFees() public {
        // Execute an order to generate fees
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            1e18,
            2000e18,
            1,
            uint64(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();
        
        vm.prank(bob);
        orderBook.executeOrder(orderHash, 1e18);
        
        // Collect fees
        uint256 feeRecipientBaseBefore = baseToken.balanceOf(feeRecipient);
        orderBook.collectFees();
        
        // Verify fees were collected
        assertTrue(baseToken.balanceOf(feeRecipient) > feeRecipientBaseBefore);
    }
    
    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testGetUserOrders() public {
        vm.startPrank(alice);
        
        bytes32 hash1 = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        bytes32 hash2 = orderBook.placeOrder(1e18, 2000e18, 1, uint64(block.timestamp + 1 days), true);
        
        bytes32[] memory userOrders = orderBook.getUserOrders(alice);
        
        assertEq(userOrders.length, 2);
        assertEq(userOrders[0], hash1);
        assertEq(userOrders[1], hash2);
        
        vm.stopPrank();
    }
    
    function testCalculateQuoteAmount() public {
        uint256 quoteAmount = orderBook.calculateQuoteAmount(1e18, 2000e18);
        assertEq(quoteAmount, 2000e18);
    }
    
    function testIsOrderExecutable() public {
        vm.startPrank(alice);
        bytes32 orderHash = orderBook.placeOrder(
            1e18,
            2000e18,
            1,
            uint64(block.timestamp + 1 days),
            true
        );
        
        assertTrue(orderBook.isOrderExecutable(orderHash));
        
        // Cancel order
        orderBook.cancelOrder(orderHash);
        
        assertFalse(orderBook.isOrderExecutable(orderHash));
        
        vm.stopPrank();
    }
}
