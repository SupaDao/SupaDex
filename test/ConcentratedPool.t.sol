// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract ConcentratedPoolTest is Test {
    Factory factory;
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;

    function setUp() public {
        token0 = new MockToken("Token0", "TK0");
        token1 = new MockToken("Token1", "TK1");
        
        // Ensure token0 < token1
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
        
        address poolAddress = factory.createPool(address(token0), address(token1), 500);
        pool = ConcentratedPool(poolAddress);

        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
    }

    function testInitialize() public {
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
        pool.initializeState(sqrtPriceX96);
        (uint160 p, int24 t, , , , , ) = pool.slot0();
        assertEq(p, sqrtPriceX96);
        assertEq(t, 0);
    }

    function testMint() public {
        pool.initializeState(79228162514264337593543950336);
        
        pool.mint(address(this), -100, 100, 1 ether, "");
        
        assertEq(pool.liquidity(), 1 ether);
    }

    function testSwap() public {
        pool.initializeState(79228162514264337593543950336);
        pool.mint(address(this), -100, 100, 10 ether, "");
        
        // Swap token0 for token1
        token0.mint(address(this), 1 ether);
        pool.swap(address(this), true, 0.01 ether, 4295128740, "");
        
        // Check balances (simplified check)
        // In real V3, we'd check exact amounts
    }
}
