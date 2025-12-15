// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../contracts/core/ConcentratedPool.sol";
import "../contracts/core/BatchAuction.sol";
import "../contracts/core/Factory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract SecurityFeaturesTest is Test {
    ConcentratedPool pool;
    BatchAuction auction;
    Factory factory;
    MockToken token0;
    MockToken token1;
    
    address owner = address(this);
    address pauser = address(0x1);
    address breaker = address(0x2);
    address user = address(0x3);
    address relayer = address(0x4);

    function setUp() public {
        token0 = new MockToken();
        token1 = new MockToken();
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        factory = new Factory();
        
        // --- Deploy ConcentratedPool ---
        ConcentratedPool poolImpl = new ConcentratedPool();
        
        bytes memory poolInitData = abi.encodeWithSelector(
            ConcentratedPool.initialize.selector,
            address(factory),
            address(token0),
            address(token1),
            3000,
            60
        );

        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), poolInitData);
        pool = ConcentratedPool(address(poolProxy));

        // --- Deploy BatchAuction ---
        BatchAuction auctionImpl = new BatchAuction();
        bytes memory auctionInitData = abi.encodeWithSelector(
            BatchAuction.initialize.selector,
            address(token0),
            address(token1),
            10, // 10 blocks duration
            100, // min order size
            500, // max price deviation
            10 // fee bps
        );
        ERC1967Proxy auctionProxy = new ERC1967Proxy(address(auctionImpl), auctionInitData);
        auction = BatchAuction(address(auctionProxy));

        // --- Setup Roles ---
        vm.startPrank(address(factory));
        pool.setPauser(pauser, true);
        pool.setCircuitBreaker(breaker, true);
        vm.stopPrank();
        
        auction.grantRole(auction.PAUSER_ROLE(), pauser);
        auction.grantRole(auction.RELAYER_ROLE(), relayer);

        // --- Setup Tokens ---
        token0.transfer(user, 10000 * 10**18);
        token1.transfer(user, 10000 * 10**18);
        
        vm.startPrank(user);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token0.approve(address(auction), type(uint256).max);
        token1.approve(address(auction), type(uint256).max);
        vm.stopPrank();

        // Initialize pool state
        pool.initializeState(79228162514264337593543950336); // sqrt(1)
    }

    function testPool_Pausable_RestrictsOperations() public {
        // Add some liquidity first so we can try to burn/swap later
        vm.prank(user);
        pool.mint(user, -60, 60, 1000, "");

        vm.prank(pauser);
        pool.pause();

        assertTrue(pool.paused());

        vm.startPrank(user);
        
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.mint(user, -120, 120, 1000, "");
        
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.burn(-60, 60, 100);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.collect(user, -60, 60, 100, 100);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.swap(user, true, 100, 70000000000000000000000000000, "");

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.flash(user, 100, 100, "");
        
        vm.stopPrank();

        // Unpause - need to wait for cooldown period
        // Pool has default cooldown configured, so we need to wait
        vm.warp(block.timestamp + 2 hours);
        vm.prank(pauser);
        pool.unpause();
        assertFalse(pool.paused());
        
        // Operations should work now
        vm.prank(user);
        pool.swap(user, true, 100, 70000000000000000000000000000, "");
    }

    function testPool_EmergencyWithdraw() public {
        // Send tokens to pool (user sends by mistake or fee accumulation)
        uint256 amount = 50 ether;
        token0.transfer(address(pool), amount);
        
        // Try withdraw when not paused
        vm.prank(pauser);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        pool.emergencyWithdraw(address(token0), amount, pauser);

        // Pause
        vm.prank(pauser);
        pool.pause();

        // Withdraw
        uint256 balBefore = token0.balanceOf(pauser);
        vm.prank(pauser);
        pool.emergencyWithdraw(address(token0), amount, pauser);
        uint256 balAfter = token0.balanceOf(pauser);
        
        assertEq(balAfter - balBefore, amount);
    }

    function testPool_CircuitBreaker_Volume() public {
        // Configure low volume limit
        vm.prank(breaker);
        pool.setCircuitBreakerConfig(500, 1000, 1 hours, true);

        // User mints liquidity
        vm.prank(user);
        pool.mint(user, -600, 600, 100000, "");

        // Swap within limit - should not pause
        vm.prank(user);
        pool.swap(user, true, 500, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        assertFalse(pool.paused());

        // Swap exceeding limit in same block - should trigger pause
        vm.prank(user);
        pool.swap(user, true, 600, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        assertTrue(pool.paused());
    }

    function testPool_CircuitBreaker_Cooldown() public {
        // Trigger pause via volume breaker
        vm.prank(breaker);
        pool.setCircuitBreakerConfig(500, 10, 1 hours, true);
        
        vm.prank(user);
        pool.mint(user, -600, 600, 100000, "");
        
        vm.prank(user);
        pool.swap(user, true, 20, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        assertTrue(pool.paused());

        // Try unpause immediately
        vm.prank(pauser);
        vm.expectRevert("Cooldown active");
        pool.unpause();

        // Wait part of cooldown
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(pauser);
        vm.expectRevert("Cooldown active");
        pool.unpause();

        // Wait full cooldown
        vm.warp(block.timestamp + 31 minutes); // total > 1 hour
        vm.prank(pauser);
        pool.unpause();
        assertFalse(pool.paused());
    }

    function testBatchAuction_Pausable() public {
        vm.prank(pauser);
        auction.pause();

        vm.startPrank(user);
        
        bytes32 commitment = keccak256(abi.encodePacked("order"));
        
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        auction.commitOrder(commitment);
        
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        auction.commitOrderWithLock(commitment, 100, true);
        
        vm.stopPrank();
    }

    function testBatchAuction_EmergencyWithdraw() public {
        uint256 amount = 50 ether;
        token0.transfer(address(auction), amount);

        vm.prank(pauser);
        auction.pause();

        uint256 balBefore = token0.balanceOf(pauser);
        vm.prank(pauser);
        auction.emergencyWithdraw(address(token0), amount, pauser);
        uint256 balAfter = token0.balanceOf(pauser);
        
        assertEq(balAfter - balBefore, amount);
    }
}
