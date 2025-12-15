// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {TestHelper} from "./TestHelper.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {TickMathOptimized} from "../contracts/libraries/TickMathOptimized.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract OracleTest is TestHelper {
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    
    function setUp() public {
        token0 = new MockToken("Token0", "TK0");
        token1 = new MockToken("Token1", "TK1");
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        deployFactory();
        
        pool = createPool(address(token0), address(token1), 3000);
        
        // Initialize pool - this records first observation
        pool.initializeState(79228162514264337593543950336); // 1:1 price
        
        // Add liquidity
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        
        pool.mint(address(this), -887220, 887220, 100 ether, "");
    }
    
    function testOracle_InitialObservation() public view {
        (, , , uint16 observationCardinality, , , ) = pool.slot0();
        
        assertEq(observationCardinality, 1, "Should have 1 observation after init");
    }
    
    function testOracle_ObservationAfterSwap() public {
        // Perform a swap to trigger observation update
        token0.mint(address(this), 1 ether);
        pool.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        // Observations are recorded, cardinality should still be 1 until we grow it
        (, , , uint16 observationCardinality, , , ) = pool.slot0();
        assertEq(observationCardinality, 1, "Cardinality should still be 1");
    }
    
    function testOracle_CardinalityGrowth() public {
        uint16 newCardinality = 10;
        
        pool.increaseObservationCardinalityNext(newCardinality);
        
        (, , , , uint16 observationCardinalityNext, , ) = pool.slot0();
        assertEq(observationCardinalityNext, newCardinality, "Cardinality next should be updated");
        
        // Perform swaps to fill observations
        for (uint i = 0; i < newCardinality; i++) {
            vm.warp(block.timestamp + 10);
            token0.mint(address(this), 0.1 ether);
            pool.swap(address(this), true, 0.1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        }
        
        (, , , uint16 observationCardinality, , , ) = pool.slot0();
        assertEq(observationCardinality, newCardinality, "Cardinality should grow");
    }
    
    function testOracle_TWAPCalculation() public {
        // Grow cardinality first
        pool.increaseObservationCardinalityNext(10);
        
        // Record initial price
        (, int24 initialTick, , , , , ) = pool.slot0();
        
        // Perform swap to change price
        vm.warp(block.timestamp + 100);
        token0.mint(address(this), 10 ether);
        pool.swap(address(this), true, 10 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        // Wait some time
        vm.warp(block.timestamp + 100);
        
        // Query TWAP
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 100;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 twapTick = int24(tickCumulativesDelta / 100);
        
        // TWAP should be between initial and current tick
        (, int24 currentTick, , , , , ) = pool.slot0();
        
        assertTrue(twapTick <= initialTick && twapTick >= currentTick, "TWAP should be between initial and current");
    }
    

    
    function testOracle_InsufficientHistory() public {
        // Try to query before we have enough history
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1000; // Way in the past
        secondsAgos[1] = 0;
        
        vm.expectRevert(); // Should revert with "OLD" or similar
        pool.observe(secondsAgos);
    }
    
    function testOracle_CardinalityWrapAround() public {
        uint16 cardinality = 3;
        pool.increaseObservationCardinalityNext(cardinality);
        
        // Initial state: index=0, card=1 (or implicitly 0 but init sets 1). 
        // Note: initializeState sets card=1.
        
        // Initial (t=1).
        
        // Swap 1 -> t=11
        vm.warp(11);
        assertEq(block.timestamp, 11, "TS 11");
        token0.mint(address(this), 0.1 ether);
        pool.swap(address(this), true, 0.1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        (, , uint16 index1, uint16 card1, , , ) = pool.slot0();
        assertEq(card1, 3, "Cardinality should be 3");
        assertEq(index1, 1, "Index should be 1");
        
        // Swap 2 -> t=21
        vm.warp(21);
        assertEq(block.timestamp, 21, "TS 21");
        token0.mint(address(this), 0.1 ether);
        pool.swap(address(this), true, 0.1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        (, , uint16 index2, , , , ) = pool.slot0();
        assertEq(index2, 2, "Index should be 2");
        
        // Swap 3 -> t=31
        vm.warp(31);
        assertEq(block.timestamp, 31, "TS 31");
        token0.mint(address(this), 0.1 ether);
        pool.swap(address(this), true, 0.1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        (, , uint16 index3, , , , ) = pool.slot0();
        assertEq(index3, 0, "Index should wrap to 0");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 15;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        assertLt(tickCumulatives[1], tickCumulatives[0]);
    }
    
    function testOracle_MultipleObservations() public {
        pool.increaseObservationCardinalityNext(5);
        
        uint256 t = 1;
        vm.warp(t); // Start at 1
        
        // Create multiple observations over time
        for (uint i = 0; i < 5; i++) {
            t += 60;
            vm.warp(t); // 1 minute intervals
            token0.mint(address(this), 0.5 ether);
            pool.swap(address(this), true, 0.5 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        }
        
        // Should be able to query observations
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 200; // 4 minutes ago
        secondsAgos[1] = 0;   // now
        
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        
        // Tick cumulative should have grown (become more negative so less than previous)
        assertLt(tickCumulatives[1], tickCumulatives[0], "Tick cumulative should change");
    }
    
    function testOracle_LargeTimeGap() public {
        pool.increaseObservationCardinalityNext(5);
        
        // Create observation
        token0.mint(address(this), 1 ether);
        pool.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        // Large time gap
        vm.warp(block.timestamp + 1 days);
        
        // Create another observation
        token0.mint(address(this), 1 ether);
        pool.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        // Should still be able to query
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1 hours;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        // Tick is negative, so cumulative decreases
        assertLt(tickCumulatives[1], tickCumulatives[0], "Should handle large gaps");
    }
    
    function testOracle_PriceAccumulation() public {
        pool.increaseObservationCardinalityNext(10);
        
        // Record tick cumulative at start
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        
        // INITIAL SWAP to change tick from 0
        token0.mint(address(this), 1 ether);
        pool.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");

        (int56[] memory tickCumulativesBefore, ) = pool.observe(secondsAgos);
        
        // Wait and perform swap
        vm.warp(block.timestamp + 100);
        
        // Check tick cumulative grew
        (int56[] memory tickCumulativesAfter, ) = pool.observe(secondsAgos);
        
        // Since tick is negative (swap true), cumulative decreases (becomes more negative)
        // So After < Before
        assertLt(tickCumulativesAfter[0], tickCumulativesBefore[0], "Tick cumulative should change over time");
    }
    
    function testOracle_ConsistentTWAP() public {
        pool.increaseObservationCardinalityNext(10);
        
        uint256 t = 1;
        vm.warp(t);

        // Create stable price over time
        for (uint i = 0; i < 5; i++) {
            t += 60;
            vm.warp(t);
            // Small swaps to maintain roughly same price
            token0.mint(address(this), 0.01 ether);
            pool.swap(address(this), true, 0.01 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        }
        
        // Query TWAP
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 240;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 twapTick = int24(tickCumulativesDelta / 240);
        
        (, int24 currentTick, , , , , ) = pool.slot0();
        
        // TWAP should be close to current tick for stable price
        int24 deviation = twapTick > currentTick ? twapTick - currentTick : currentTick - twapTick;
        assertLt(deviation, 100, "TWAP should be close to current for stable price");
    }
}
