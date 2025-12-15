// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {Router} from "../contracts/periphery/Router.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TickMathOptimized} from "../contracts/libraries/TickMathOptimized.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract ConcentratedPoolFuzzTest is Test {
    Factory factory;
    Router router;
    ConcentratedPool pool;
    ConcentratedPool poolAB;
    ConcentratedPool poolBC;
    MockToken token0;
    MockToken token1;
    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;

    function setUp() public {
        // Setup for single pool tests
        token0 = new MockToken("Token0", "TK0");
        token1 = new MockToken("Token1", "TK1");
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        Factory factoryImpl = new Factory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(Factory.initialize, (address(this)))
        );
        factory = Factory(address(factoryProxy));
        
        ConcentratedPool poolImpl = new ConcentratedPool();
        factory.setImplementation(keccak256("ConcentratedPool"), address(poolImpl));
        
        address poolAddress = factory.createPool(address(token0), address(token1), 3000);
        pool = ConcentratedPool(poolAddress);

        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        
        pool.initializeState(79228162514264337593543950336);
        
        // Setup for multi-hop tests
        tokenA = new MockToken("TokenA", "TKA");
        tokenB = new MockToken("TokenB", "TKB");
        tokenC = new MockToken("TokenC", "TKC");
        
        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);
        
        for(uint i=0; i<3; i++) {
            for(uint j=i+1; j<3; j++) {
                if(tokens[i] > tokens[j]) {
                    address temp = tokens[i];
                    tokens[i] = tokens[j];
                    tokens[j] = temp;
                }
            }
        }
        tokenA = MockToken(tokens[0]);
        tokenB = MockToken(tokens[1]);
        tokenC = MockToken(tokens[2]);
        
        router = new Router(address(factory));
        
        factory.createPool(address(tokenA), address(tokenB), 3000);
        factory.createPool(address(tokenB), address(tokenC), 3000);
        
        poolAB = ConcentratedPool(factory.getPool(address(tokenA), address(tokenB), 3000));
        poolBC = ConcentratedPool(factory.getPool(address(tokenB), address(tokenC), 3000));
        
        poolAB.initializeState(TickMathOptimized.getSqrtRatioAtTick(0));
        poolBC.initializeState(TickMathOptimized.getSqrtRatioAtTick(0));
        
        tokenA.approve(address(poolAB), type(uint256).max);
        tokenB.approve(address(poolAB), type(uint256).max);
        tokenB.approve(address(poolBC), type(uint256).max);
        tokenC.approve(address(poolBC), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        
        poolAB.mint(address(this), -887220, 887220, 100 ether, "");
        poolBC.mint(address(this), -887220, 887220, 100 ether, "");
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP AMOUNT FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SwapExtremeAmounts(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.0001 ether, 10 ether);
        
        pool.mint(address(this), -1200, 1200, 100 ether, "");
        
        token0.mint(address(this), amountIn);
        
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            true,
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(amountIn),
            4295128740,
            ""
        );
        
        assertGt(amount0, 0, "Should take token0");
        assertLt(amount1, 0, "Should give token1");
    }

    function testFuzz_SwapDirection(bool zeroForOne, uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 1 ether);
        
        pool.mint(address(this), -1200, 1200, 100 ether, "");
        
        if (zeroForOne) {
            token0.mint(address(this), amountIn);
        } else {
            token1.mint(address(this), amountIn);
        }
        
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(amountIn),
            zeroForOne ? TickMathOptimized.MIN_SQRT_RATIO + 1 : TickMathOptimized.MAX_SQRT_RATIO - 1,
            ""
        );
        
        if (zeroForOne) {
            assertGt(amount0, 0);
            assertLt(amount1, 0);
        } else {
            assertLt(amount0, 0);
            assertGt(amount1, 0);
        }
    }

    function testFuzz_ConsecutiveSwaps(uint8 numSwaps, uint256 amountPerSwap) public {
        numSwaps = uint8(bound(numSwaps, 1, 10));
        amountPerSwap = bound(amountPerSwap, 0.01 ether, 0.5 ether);
        
        pool.mint(address(this), -887220, 887220, 1000 ether, "");
        
        for(uint i = 0; i < numSwaps; i++) {
            token0.mint(address(this), amountPerSwap);
            
            pool.swap(
                address(this),
                true,
                // forge-lint: disable-next-line(unsafe-typecast)
                int256(amountPerSwap),
                4295128740,
                ""
            );
        }
        
        // Pool should still be functional
        assertTrue(pool.liquidity() > 0);
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDITY POSITION FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_MintBurn(uint128 amount, int24 tickLower, int24 tickUpper) public {
        vm.assume(amount > 1000 && amount < 1e24);
        tickLower = int24(bound(tickLower, -887200, 887100));
        tickUpper = int24(bound(tickUpper, tickLower + 60, 887200));
        
        // Ensure tick spacing of 60
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (tickLower / 60) * 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (tickUpper / 60) * 60;
        
        vm.assume(tickLower < tickUpper);
        
        (uint256 amount0, uint256 amount1) = pool.mint(address(this), tickLower, tickUpper, amount, "");
        
        assertGt(amount0 + amount1, 0, "Should require at least one token");
        
        (uint256 burnAmount0, uint256 burnAmount1) = pool.burn(tickLower, tickUpper, amount);
        
        // Allow for small rounding differences
        assertGe(burnAmount0, amount0 * 95 / 100, "Burn should return similar amount0");
        assertGe(burnAmount1, amount1 * 95 / 100, "Burn should return similar amount1");
    }

    function testFuzz_OverlappingPositions(
        uint128 amount1,
        uint128 amount2,
        int24 tick1Lower,
        int24 tick1Upper,
        int24 tick2Lower,
        int24 tick2Upper
    ) public {
        amount1 = uint128(bound(amount1, 1e18, 1e20));
        amount2 = uint128(bound(amount2, 1e18, 1e20));
        
        tick1Lower = int24(bound(tick1Lower, -887160, -60));
        tick1Upper = int24(bound(tick1Upper, 60, 887160));
        tick2Lower = int24(bound(tick2Lower, -887160, -60));
        tick2Upper = int24(bound(tick2Upper, 60, 887160));
        
        // Ensure tick spacing
        // forge-lint: disable-next-line(divide-before-multiply)
        tick1Lower = (tick1Lower / 60) * 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        tick1Upper = (tick1Upper / 60) * 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        tick2Lower = (tick2Lower / 60) * 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        tick2Upper = (tick2Upper / 60) * 60;
        
        vm.assume(tick1Lower < tick1Upper);
        vm.assume(tick2Lower < tick2Upper);
        vm.assume(tick1Upper - tick1Lower >= 120);
        vm.assume(tick2Upper - tick2Lower >= 120);
        
        pool.mint(address(this), tick1Lower, tick1Upper, amount1, "");
        pool.mint(address(this), tick2Lower, tick2Upper, amount2, "");
        
        // Both positions should exist
        assertTrue(pool.liquidity() > 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE MANIPULATION FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_LargeSwapImpact(uint256 swapSize) public {
        swapSize = bound(swapSize, 1 ether, 50 ether);
        
        pool.mint(address(this), -887220, 887220, 100 ether, "");
        
        (uint160 priceBefore, , , , , , ) = pool.slot0();
        
        token0.mint(address(this), swapSize);
        pool.swap(
            address(this),
            true,
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(swapSize),
            TickMathOptimized.MIN_SQRT_RATIO + 1,
            ""
        );
        
        (uint160 priceAfter, , , , , , ) = pool.slot0();
        
        // Larger swaps should have larger price impact
        assertLt(priceAfter, priceBefore, "Price should decrease");
        
        if (swapSize > 10 ether) {
            // Large swap should have significant impact
            assertTrue(priceBefore - priceAfter > priceBefore / 100, "Large swap should move price >1%");
        }
    }

    function testFuzz_SwapInvariant(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.1 ether);
        
        pool.mint(address(this), -1200, 1200, 100 ether, "");
        
        uint256 balance0Before = token0.balanceOf(address(pool));
        uint256 balance1Before = token1.balanceOf(address(pool));
        
        token0.mint(address(this), amountIn);
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            true,
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(amountIn),
            4295128740,
            ""
        );
        
        uint256 balance0After = token0.balanceOf(address(pool));
        uint256 balance1After = token1.balanceOf(address(pool));
        
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(int256(balance0After) - int256(balance0Before), amount0, "Pool balance0 should match swap amount0");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(int256(balance1After) - int256(balance1Before), amount1, "Pool balance1 should match swap amount1");
        
        assertGt(amount0, 0, "Should take token0");
        assertLt(amount1, 0, "Should give token1");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-HOP ROUTING FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_MultiHopSwap(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.01 ether, 1 ether);
        
        tokenA.mint(address(this), amountIn);
        
        bytes memory path = abi.encodePacked(
            address(tokenA),
            uint24(3000),
            address(tokenB),
            uint24(3000),
            address(tokenC)
        );
        
        Router.ExactInputParams memory params = Router.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: 0,
            deadline: block.timestamp + 1000
        });
        
        uint256 balanceCBefore = tokenC.balanceOf(address(this));
        uint256 amountOut = router.exactInput(params);
        uint256 balanceCAfter = tokenC.balanceOf(address(this));
        
        assertGt(amountOut, 0, "Should receive tokens");
        assertEq(balanceCAfter - balanceCBefore, amountOut, "Balance should match");
    }

    function testFuzz_MultiHopPriceImpact(uint256 smallAmount, uint256 largeAmount) public {
        smallAmount = bound(smallAmount, 0.01 ether, 0.1 ether);
        largeAmount = bound(largeAmount, 1 ether, 10 ether);
        
        vm.assume(largeAmount > smallAmount * 5);
        
        bytes memory path = abi.encodePacked(
            address(tokenA),
            uint24(3000),
            address(tokenB),
            uint24(3000),
            address(tokenC)
        );
        
        // Small swap
        tokenA.mint(address(this), smallAmount);
        Router.ExactInputParams memory paramsSmall = Router.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: smallAmount,
            amountOutMinimum: 0,
            deadline: block.timestamp + 1000
        });
        uint256 smallOut = router.exactInput(paramsSmall);
        
        // Large swap
        tokenA.mint(address(this), largeAmount);
        Router.ExactInputParams memory paramsLarge = Router.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: largeAmount,
            amountOutMinimum: 0,
            deadline: block.timestamp + 1000
        });
        uint256 largeOut = router.exactInput(paramsLarge);
        
        // Large swap should have worse rate
        uint256 smallRate = (smallOut * 1e18) / smallAmount;
        uint256 largeRate = (largeOut * 1e18) / largeAmount;
        
        assertLt(largeRate, smallRate, "Large swap should have worse rate");
    }

    function testFuzz_PriceMovement(bool zeroForOne, uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.05 ether);
        
        pool.mint(address(this), -1200, 1200, 100 ether, "");
        
        (uint160 priceBefore, , , , , , ) = pool.slot0();
        
        if (zeroForOne) {
            token0.mint(address(this), amountIn);
            // forge-lint: disable-next-line(unsafe-typecast)
            pool.swap(address(this), true, int256(amountIn), TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        } else {
            token1.mint(address(this), amountIn);
            // forge-lint: disable-next-line(unsafe-typecast)
            pool.swap(address(this), false, int256(amountIn), TickMathOptimized.MAX_SQRT_RATIO - 1, "");
        }
        
        (uint160 priceAfter, , , , , , ) = pool.slot0();
        
        if (zeroForOne) {
            assertLt(priceAfter, priceBefore, "Price should decrease when selling token0");
        } else {
            assertGt(priceAfter, priceBefore, "Price should increase when selling token1");
        }
    }
}
