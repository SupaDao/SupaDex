// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {Router} from "../contracts/periphery/Router.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMathOptimized} from "../contracts/libraries/TickMathOptimized.sol";

/// @title Fork Tests for DEX Protocol
/// @notice Tests protocol against mainnet state and real tokens
/// @dev Run with: forge test --match-contract ForkTest --fork-url $ETH_RPC_URL
contract ForkTest is Test {
    Factory factory;
    Router router;
    
    // Mainnet token addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    
    ConcentratedPool poolWethUsdc;
    ConcentratedPool poolWethDai;
    
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        // Deploy factory
        Factory factoryImpl = new Factory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(Factory.initialize, (address(this)))
        );
        factory = Factory(address(factoryProxy));
        
        // Deploy router
        router = new Router(address(factory));
        
        // Set pool implementation
        ConcentratedPool poolImpl = new ConcentratedPool();
        factory.setImplementation(keccak256("ConcentratedPool"), address(poolImpl));
        
        // Create pools with real tokens
        factory.createPool(WETH, USDC, 3000);
        factory.createPool(WETH, DAI, 3000);
        
        poolWethUsdc = ConcentratedPool(factory.getPool(WETH, USDC, 3000));
        poolWethDai = ConcentratedPool(factory.getPool(WETH, DAI, 3000));
        
        // Initialize pools at reasonable prices
        // WETH/USDC ~= $2000, WETH/DAI ~= $2000
        poolWethUsdc.initializeState(TickMathOptimized.getSqrtRatioAtTick(0));
        poolWethDai.initializeState(TickMathOptimized.getSqrtRatioAtTick(0));
        
        // Fund test accounts
        deal(WETH, address(this), 100 ether);
        deal(USDC, address(this), 1000000e6); // 1M USDC
        deal(DAI, address(this), 1000000 ether); // 1M DAI
        
        deal(WETH, alice, 10 ether);
        deal(USDC, alice, 100000e6);
        
        // Approve tokens
        IERC20(WETH).approve(address(poolWethUsdc), type(uint256).max);
        IERC20(USDC).approve(address(poolWethUsdc), type(uint256).max);
        IERC20(WETH).approve(address(poolWethDai), type(uint256).max);
        IERC20(DAI).approve(address(poolWethDai), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(DAI).approve(address(router), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        MAINNET FORK INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function testFork_RealTokenSwap() public {
        // Add liquidity
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        
        // Swap WETH for USDC
        poolWethUsdc.swap(
            address(this),
            true,
            1 ether,
            TickMathOptimized.MIN_SQRT_RATIO + 1,
            ""
        );
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        
        assertGt(usdcAfter, usdcBefore, "Should receive USDC");
    }

    function testFork_MultiTokenDecimals() public {
        // USDC has 6 decimals, DAI has 18 decimals
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        poolWethDai.mint(address(this), -887220, 887220, 10 ether, "");
        
        // Swap should work with different decimal tokens
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        poolWethUsdc.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));
        poolWethDai.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        uint256 daiAfter = IERC20(DAI).balanceOf(address(this));
        
        assertGt(usdcAfter, usdcBefore, "Should receive USDC");
        assertGt(daiAfter, daiBefore, "Should receive DAI");
    }

    function testFork_MultiHopRouting() public {
        // Add liquidity to both pools
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        poolWethDai.mint(address(this), -887220, 887220, 10 ether, "");
        
        // Swap USDC -> WETH -> DAI
        bytes memory path = abi.encodePacked(
            USDC,
            uint24(3000),
            WETH,
            uint24(3000),
            DAI
        );
        
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));
        
        Router.ExactInputParams memory params = Router.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: 1000e6, // 1000 USDC
            amountOutMinimum: 0,
            deadline: block.timestamp + 1000
        });
        
        router.exactInput(params);
        
        uint256 daiAfter = IERC20(DAI).balanceOf(address(this));
        
        assertGt(daiAfter, daiBefore, "Should receive DAI");
    }

    /*//////////////////////////////////////////////////////////////
                        REAL TOKEN TESTING
    //////////////////////////////////////////////////////////////*/

    function testFork_RealTokenBalances() public {
        // Verify we can interact with real tokens
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        
        assertGt(wethBalance, 0, "Should have WETH");
        assertGt(usdcBalance, 0, "Should have USDC");
    }

    function testFork_RealTokenTransfers() public {
        uint256 amount = 1 ether;
        
        IERC20(WETH).transfer(alice, amount);
        
        assertEq(IERC20(WETH).balanceOf(alice), 10 ether + amount, "Alice should receive WETH");
    }

    /*//////////////////////////////////////////////////////////////
                        GAS BENCHMARKING
    //////////////////////////////////////////////////////////////*/

    function testGas_Mint() public {
        uint256 gasBefore = gasleft();
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("Gas used for mint", gasUsed);
        
        // Should be reasonable (< 500k gas)
        assertLt(gasUsed, 500000, "Mint should use < 500k gas");
    }

    function testGas_Swap() public {
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        
        uint256 gasBefore = gasleft();
        poolWethUsdc.swap(
            address(this),
            true,
            1 ether,
            TickMathOptimized.MIN_SQRT_RATIO + 1,
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("Gas used for swap", gasUsed);
        
        // Should be reasonable (< 200k gas)
        assertLt(gasUsed, 200000, "Swap should use < 200k gas");
    }

    function testGas_Burn() public {
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        
        uint256 gasBefore = gasleft();
        poolWethUsdc.burn(-887220, 887220, 5 ether);
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("Gas used for burn", gasUsed);
        
        // Should be reasonable (< 200k gas)
        assertLt(gasUsed, 200000, "Burn should use < 200k gas");
    }

    function testGas_MultiHopSwap() public {
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        poolWethDai.mint(address(this), -887220, 887220, 10 ether, "");
        
        bytes memory path = abi.encodePacked(
            USDC,
            uint24(3000),
            WETH,
            uint24(3000),
            DAI
        );
        
        Router.ExactInputParams memory params = Router.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: 1000e6,
            amountOutMinimum: 0,
            deadline: block.timestamp + 1000
        });
        
        uint256 gasBefore = gasleft();
        router.exactInput(params);
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("Gas used for multi-hop swap", gasUsed);
        
        // Should be reasonable (< 400k gas for 2 hops)
        assertLt(gasUsed, 400000, "Multi-hop swap should use < 400k gas");
    }

    function testGas_Collect() public {
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        
        // Generate fees
        poolWethUsdc.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        
        uint256 gasBefore = gasleft();
        poolWethUsdc.collect(
            address(this),
            -887220,
            887220,
            type(uint128).max,
            type(uint128).max
        );
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("Gas used for collect", gasUsed);
        
        // Should be reasonable (< 150k gas)
        assertLt(gasUsed, 150000, "Collect should use < 150k gas");
    }

    /*//////////////////////////////////////////////////////////////
                        COMPARISON BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function testGas_CompareWithUniswapV3() public {
        // Note: This is a placeholder for comparison
        // In a real scenario, you would deploy Uniswap V3 contracts
        // and compare gas costs side by side
        
        poolWethUsdc.mint(address(this), -887220, 887220, 10 ether, "");
        
        uint256 gasBefore = gasleft();
        poolWethUsdc.swap(address(this), true, 1 ether, TickMathOptimized.MIN_SQRT_RATIO + 1, "");
        uint256 ourGas = gasBefore - gasleft();
        
        emit log_named_uint("Our swap gas", ourGas);
        
        // Uniswap V3 swap typically uses ~120-150k gas
        // Our implementation should be competitive
        assertLt(ourGas, 200000, "Should be competitive with Uniswap V3");
    }
}
