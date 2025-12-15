// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Router} from "../contracts/periphery/Router.sol";
import {TickMathOptimized} from "../contracts/libraries/TickMathOptimized.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract RouterTest is Test {
    Factory factory;
    Router router;
    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;

    function setUp() public {
        tokenA = new MockToken("TokenA", "TKA");
        tokenB = new MockToken("TokenB", "TKB");
        tokenC = new MockToken("TokenC", "TKC");
        
        // Sort tokens to make pool creation deterministic
        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);
        // Simple sort (bubble sort for 3 items)
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

        Factory factoryImpl = new Factory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(Factory.initialize, (address(this)))
        );
        factory = Factory(address(factoryProxy));
        
        router = new Router(address(factory));
        
        // Deploy implementations
        ConcentratedPool poolImpl = new ConcentratedPool();
        factory.setImplementation(keccak256("ConcentratedPool"), address(poolImpl));
        
        // Create pools A/B and B/C
        factory.createPool(address(tokenA), address(tokenB), 500);
        factory.createPool(address(tokenB), address(tokenC), 500);
        
        // Initialize and add liquidity
        address poolAb = factory.getPool(address(tokenA), address(tokenB), 500);
        address poolBc = factory.getPool(address(tokenB), address(tokenC), 500);
        
        ConcentratedPool(poolAb).initializeState(TickMathOptimized.getSqrtRatioAtTick(0));
        ConcentratedPool(poolBc).initializeState(TickMathOptimized.getSqrtRatioAtTick(0)); // 1:1
        
        // Mint tokens to this contract
        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);
        tokenC.mint(address(this), 1000 ether);
        
        tokenA.approve(poolAb, type(uint256).max);
        tokenB.approve(poolAb, type(uint256).max);
        tokenB.approve(poolBc, type(uint256).max);
        tokenC.approve(poolBc, type(uint256).max);
        
        ConcentratedPool(poolAb).mint(address(this), -887220, 887220, 1000 ether, "");
        ConcentratedPool(poolBc).mint(address(this), -887220, 887220, 1000 ether, "");
        
        // Approve router
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
    }

    function testExactOutputSingle() public {
        // Swap A -> B, get exactly 1 ether B
        uint256 amountOut = 1 ether;
        uint256 amountInMax = 2 ether;
        
        Router.ExactOutputSingleParams memory params = Router.ExactOutputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            fee: 500,
            recipient: address(this),
            amountOut: amountOut,
            amountInMaximum: amountInMax,
            sqrtPriceLimitX96: 0,
            deadline: block.timestamp + 1000
        });

        uint256 balBBefore = tokenB.balanceOf(address(this));
        uint256 amountIn = router.exactOutputSingle(params);
        uint256 balBAfter = tokenB.balanceOf(address(this));
        
        assertEq(balBAfter - balBBefore, amountOut);
        assertTrue(amountIn < amountInMax);
    }

    function testExactInputSingle() public {
        // Swap A -> B, exact input 1 ether A
        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 0;
        
        Router.ExactInputSingleParams memory params = Router.ExactInputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            fee: 500,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0,
            deadline: block.timestamp + 1000
        });
        
        uint256 balABefore = tokenA.balanceOf(address(this));
        uint256 balBBefore = tokenB.balanceOf(address(this));
        
        uint256 amountOut = router.exactInputSingle(params);
        
        uint256 balAAfter = tokenA.balanceOf(address(this));
        uint256 balBAfter = tokenB.balanceOf(address(this));
        
        assertEq(balABefore - balAAfter, amountIn, "Should spend exactly amountIn");
        assertEq(balBAfter - balBBefore, amountOut, "Should receive amountOut");
        assertTrue(amountOut > 0, "Should receive tokens");
    }

    function testExactInputMultiHop() public {
        // Swap A -> B -> C
        // Path: A, fee, B, fee, C
        bytes memory path = abi.encodePacked(address(tokenA), uint24(500), address(tokenB), uint24(500), address(tokenC));
        
        uint256 amountIn = 1 ether;
        
        Router.ExactInputParams memory params = Router.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: 0,
            deadline: block.timestamp + 1000
        });
        
        uint256 balCBefore = tokenC.balanceOf(address(this));
        router.exactInput(params);
        uint256 balCAfter = tokenC.balanceOf(address(this));
        
        assertTrue(balCAfter > balCBefore);
    }

    function testExactOutputMultiHop() public {
        // Swap A -> B -> C, get exactly 1 ether C
        // Path: C, fee, B, fee, A (Reverse)
        bytes memory path = abi.encodePacked(address(tokenC), uint24(500), address(tokenB), uint24(500), address(tokenA));
        
        uint256 amountOut = 1 ether;
        uint256 amountInMax = 2 ether;
        
        Router.ExactOutputParams memory params = Router.ExactOutputParams({
            path: path,
            recipient: address(this),
            amountOut: amountOut,
            amountInMaximum: amountInMax,
            deadline: block.timestamp + 1000
        });
        
        uint256 balCBefore = tokenC.balanceOf(address(this));
        uint256 balABefore = tokenA.balanceOf(address(this));
        
        router.exactOutput(params);
        
        uint256 balCAfter = tokenC.balanceOf(address(this));
        uint256 balAAfter = tokenA.balanceOf(address(this));
        
        assertEq(balCAfter - balCBefore, amountOut);
        assertTrue(balABefore - balAAfter < amountInMax);
    }
}
