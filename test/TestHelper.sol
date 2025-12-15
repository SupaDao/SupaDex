// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {BatchAuction} from "../contracts/core/BatchAuction.sol";

/**
 * @title TestHelper
 * @notice Base contract for tests that need properly deployed pools via Factory
 * @dev Handles the proxy pattern setup for upgradeable contracts
 */
abstract contract TestHelper is Test {
    Factory factory;
    
    function deployFactory() internal returns (Factory) {
        // Deploy Factory implementation
        Factory factoryImpl = new Factory();
        
        // Deploy Factory proxy
        bytes memory initData = abi.encodeWithSelector(
            Factory.initialize.selector,
            address(this)
        );
        
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            initData
        );
        
        factory = Factory(address(factoryProxy));
        
        // Deploy and set ConcentratedPool implementation
        ConcentratedPool poolImpl = new ConcentratedPool();
        factory.setImplementation(keccak256("ConcentratedPool"), address(poolImpl));
        
        // Deploy and set BatchAuction implementation
        BatchAuction auctionImpl = new BatchAuction();
        factory.setImplementation(keccak256("BatchAuction"), address(auctionImpl));
        
        return factory;
    }
    
    function createPool(
        address token0,
        address token1,
        uint24 fee
    ) internal returns (ConcentratedPool) {
        address poolAddress = factory.createPool(token0, token1, fee);
        return ConcentratedPool(poolAddress);
    }
    
    function createAuction(
        address token0,
        address token1
    ) internal returns (BatchAuction) {
        address auctionAddress = factory.createAuction(token0, token1);
        return BatchAuction(auctionAddress);
    }
}
