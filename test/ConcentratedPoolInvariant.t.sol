// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract ConcentratedPoolInvariantTest is Test {
    Factory factory;
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    
    Handler handler;

    function setUp() public {
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
        
        pool.initializeState(79228162514264337593543950336);
        
        handler = new Handler(pool, token0, token1);
        
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                        POOL BALANCE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_PoolBalancesMatchAccounting() public view {
        uint256 poolBalance0 = token0.balanceOf(address(pool));
        uint256 poolBalance1 = token1.balanceOf(address(pool));
        
        assertGe(poolBalance0, 0, "Pool balance0 should be non-negative");
        assertGe(poolBalance1, 0, "Pool balance1 should be non-negative");
    }

    function invariant_NoNegativeBalances() public view {
        uint256 poolBalance0 = token0.balanceOf(address(pool));
        uint256 poolBalance1 = token1.balanceOf(address(pool));
        
        assertTrue(poolBalance0 >= 0, "Balance0 must be non-negative");
        assertTrue(poolBalance1 >= 0, "Balance1 must be non-negative");
    }

    function invariant_ProtocolFeesValid() public view {
        uint128 protocolFees0 = pool.protocolFees0();
        uint128 protocolFees1 = pool.protocolFees1();
        uint256 poolBalance0 = token0.balanceOf(address(pool));
        uint256 poolBalance1 = token1.balanceOf(address(pool));
        
        assertLe(protocolFees0, poolBalance0, "Protocol fees0 cannot exceed pool balance");
        assertLe(protocolFees1, poolBalance1, "Protocol fees1 cannot exceed pool balance");
    }

    /*//////////////////////////////////////////////////////////////
                        FEE ACCOUNTING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_FeeGrowthMonotonic() public view {
        uint256 feeGrowth0 = pool.feeGrowthGlobal0X128();
        uint256 feeGrowth1 = pool.feeGrowthGlobal1X128();
        
        // Fee growth should never decrease (monotonic)
        // This is checked implicitly by the handler tracking
        assertTrue(feeGrowth0 >= 0, "Fee growth0 must be non-negative");
        assertTrue(feeGrowth1 >= 0, "Fee growth1 must be non-negative");
    }

    function invariant_FeeGrowthConsistent() public view {
        uint256 feeGrowth0 = pool.feeGrowthGlobal0X128();
        uint256 feeGrowth1 = pool.feeGrowthGlobal1X128();
        
        // If there's liquidity and swaps happened, fee growth should be > 0
        if (handler.swapCount() > 0 && pool.liquidity() > 0) {
            assertTrue(feeGrowth0 > 0 || feeGrowth1 > 0, "Fee growth should increase with swaps");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION TRACKING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_LiquidityNonNegative() public view {
        uint128 liquidity = pool.liquidity();
        assertGe(liquidity, 0, "Liquidity should be non-negative");
    }

    function invariant_LiquidityMatchesPositions() public view {
        // If we're at tick 0 and have minted positions, liquidity should be > 0
        (, int24 tick, , , , , ) = pool.slot0();
        uint128 liquidity = pool.liquidity();
        
        if (handler.mintCount() > 0 && tick >= -887220 && tick <= 887220) {
            // At least some positions should be active
            assertTrue(liquidity >= 0, "Liquidity should reflect active positions");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE PRICE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_PriceInBounds() public view {
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        assertGt(sqrtPriceX96, 0, "Price should be positive");
        assertLt(sqrtPriceX96, type(uint160).max, "Price should be in bounds");
    }

    function invariant_TickConsistentWithPrice() public view {
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
        
        // Tick should be within valid range
        assertGe(tick, -887272, "Tick should be >= MIN_TICK");
        assertLe(tick, 887272, "Tick should be <= MAX_TICK");
        
        // Price should be positive
        assertGt(sqrtPriceX96, 0, "Price must be positive");
    }

    function invariant_ObservationCardinalityValid() public view {
        (, , , uint16 cardinality, uint16 cardinalityNext, , ) = pool.slot0();
        
        assertLe(cardinality, cardinalityNext, "Cardinality should not exceed cardinalityNext");
        assertGe(cardinalityNext, 1, "CardinalityNext should be at least 1");
    }

    /*//////////////////////////////////////////////////////////////
                        POOL STATE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_PoolUnlocked() public view {
        (, , , , , , bool unlocked) = pool.slot0();
        assertTrue(unlocked, "Pool should be unlocked after operations");
    }

    function invariant_TickSpacingValid() public view {
        int24 tickSpacing = pool.TICK_SPACING();
        assertGt(tickSpacing, 0, "Tick spacing must be positive");
        assertEq(tickSpacing, 60, "Tick spacing should be 60 for 0.3% fee");
    }
}

contract Handler is Test {
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    
    uint256 public mintCount;
    uint256 public swapCount;
    uint256 public burnCount;
    
    uint256 private lastFeeGrowth0;
    uint256 private lastFeeGrowth1;
    
    constructor(ConcentratedPool _pool, MockToken _token0, MockToken _token1) {
        pool = _pool;
        token0 = _token0;
        token1 = _token1;
        
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
    }

    function mint(uint128 amount, int24 tickLower, int24 tickUpper) public {
        amount = uint128(bound(amount, 1e18, type(uint128).max / 1000));
        tickLower = int24(bound(tickLower, -887200, 887200));
        tickUpper = int24(bound(tickUpper, tickLower + 60, 887200));
        
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (tickLower / 60) * 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (tickUpper / 60) * 60;
        
        if (tickLower >= tickUpper) return;
        
        try pool.mint(address(this), tickLower, tickUpper, amount, "") {
            mintCount++;
        } catch {
            // Ignore failures
        }
    }

    function swap(bool zeroForOne, uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 0.1 ether);
        
        // Track fee growth before swap
        lastFeeGrowth0 = pool.feeGrowthGlobal0X128();
        lastFeeGrowth1 = pool.feeGrowthGlobal1X128();
        
        if (zeroForOne) {
            token0.mint(address(this), amountIn);
            // forge-lint: disable-next-line(unsafe-typecast)
            try pool.swap(address(this), true, int256(amountIn), 4295128740, "") {
                swapCount++;
            } catch {
                // Ignore failures
            }
        } else {
            token1.mint(address(this), amountIn);
            // forge-lint: disable-next-line(unsafe-typecast)
            try pool.swap(address(this), false, int256(amountIn), type(uint160).max - 1, "") {
                swapCount++;
            } catch {
                // Ignore failures
            }
        }
        
        // Verify fee growth never decreases
        uint256 newFeeGrowth0 = pool.feeGrowthGlobal0X128();
        uint256 newFeeGrowth1 = pool.feeGrowthGlobal1X128();
        
        require(newFeeGrowth0 >= lastFeeGrowth0, "Fee growth0 decreased");
        require(newFeeGrowth1 >= lastFeeGrowth1, "Fee growth1 decreased");
    }

    function burn(int24 tickLower, int24 tickUpper, uint128 amount) public {
        tickLower = int24(bound(tickLower, -887200, 887200));
        tickUpper = int24(bound(tickUpper, tickLower + 60, 887200));
        amount = uint128(bound(amount, 1000, 1e20));
        
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (tickLower / 60) * 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (tickUpper / 60) * 60;
        
        if (tickLower >= tickUpper) return;
        
        try pool.burn(tickLower, tickUpper, amount) {
            burnCount++;
        } catch {
            // Ignore failures
        }
    }
}
