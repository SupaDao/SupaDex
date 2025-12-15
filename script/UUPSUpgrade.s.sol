// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Config} from "./Config.s.sol";

// Core contracts
import {Factory} from "../contracts/core/Factory.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {BatchAuction} from "../contracts/core/BatchAuction.sol";

/// @title UUPSUpgrade
/// @notice Script for upgrading UUPS proxies
/// @dev Handles upgrades for Factory and implementation contracts
contract UUPSUpgrade is Script, Config {
    /*//////////////////////////////////////////////////////////////
                            UPGRADE STATE
    //////////////////////////////////////////////////////////////*/
    
    struct UpgradeInfo {
        address proxy;
        address oldImplementation;
        address newImplementation;
        string contractName;
    }
    
    UpgradeInfo[] public upgrades;
    
    /*//////////////////////////////////////////////////////////////
                            MAIN UPGRADE
    //////////////////////////////////////////////////////////////*/
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("==============================================");
        console.log("UUPS Upgrade Script");
        console.log("==============================================");
        console.log("Network:", getNetworkName());
        console.log("Chain ID:", block.chainid);
        console.log("==============================================");
        
        // Load deployment addresses
        address factoryProxy = loadDeploymentAddress("factory");
        
        console.log("\nFactory Proxy:", factoryProxy);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Pre-upgrade validation
        console.log("\n[1/4] Pre-upgrade Validation...");
        preUpgradeValidation(factoryProxy);
        
        // Step 2: Deploy new implementations
        console.log("\n[2/4] Deploying New Implementations...");
        address newFactoryImpl = deployNewFactoryImplementation();
        address newPoolImpl = deployNewPoolImplementation();
        address newAuctionImpl = deployNewAuctionImplementation();
        
        // Step 3: Upgrade contracts
        console.log("\n[3/4] Upgrading Contracts...");
        upgradeFactory(factoryProxy, newFactoryImpl);
        updateImplementations(factoryProxy, newPoolImpl, newAuctionImpl);
        
        // Step 4: Post-upgrade validation
        console.log("\n[4/4] Post-upgrade Validation...");
        postUpgradeValidation(factoryProxy);
        
        vm.stopBroadcast();
        
        // Print upgrade summary
        printUpgradeSummary();
    }
    
    /*//////////////////////////////////////////////////////////////
                        VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Validates contracts before upgrade
    function preUpgradeValidation(address factoryProxy) internal view {
        // Check that proxy exists
        require(factoryProxy.code.length > 0, "Factory proxy not deployed");
        
        // Get current implementation
        // Get current implementation
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address currentImpl = address(uint160(uint256(vm.load(factoryProxy, implSlot))));
        console.log("  Current Factory implementation:", currentImpl);
        
        // Verify proxy is working
        Factory factory = Factory(factoryProxy);
        address poolImpl = factory.concentratedPoolImplementation();
        address auctionImpl = factory.batchAuctionImplementation();
        
        console.log("  Current ConcentratedPool implementation:", poolImpl);
        console.log("  Current BatchAuction implementation:", auctionImpl);
        
        console.log("  Pre-upgrade validation passed");
    }
    
    /// @notice Validates contracts after upgrade
    function postUpgradeValidation(address factoryProxy) internal view {
        // Verify new implementation is set
        // Verify new implementation is set
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address newImpl = address(uint160(uint256(vm.load(factoryProxy, implSlot))));
        console.log("  New Factory implementation:", newImpl);
        
        // Verify proxy is still working
        Factory factory = Factory(factoryProxy);
        address poolImpl = factory.concentratedPoolImplementation();
        address auctionImpl = factory.batchAuctionImplementation();
        
        console.log("  New ConcentratedPool implementation:", poolImpl);
        console.log("  New BatchAuction implementation:", auctionImpl);
        
        // Smoke test: try to read a value
        try factory.concentratedPoolImplementation() returns (address) {
            console.log("  Smoke test passed: Factory is responsive");
        } catch {
            revert("Smoke test failed: Factory is not responsive");
        }
        
        console.log("  Post-upgrade validation passed");
    }
    
    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Deploys new Factory implementation
    function deployNewFactoryImplementation() internal returns (address) {
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address oldImpl = address(uint160(uint256(vm.load(loadDeploymentAddress("factory"), implSlot))));
        address newImpl = address(new Factory());
        
        console.log("  Deployed new Factory implementation:", newImpl);
        
        upgrades.push(UpgradeInfo({
            proxy: loadDeploymentAddress("factory"),
            oldImplementation: oldImpl,
            newImplementation: newImpl,
            contractName: "Factory"
        }));
        
        return newImpl;
    }
    
    /// @notice Deploys new ConcentratedPool implementation
    function deployNewPoolImplementation() internal returns (address) {
        address oldImpl = Factory(loadDeploymentAddress("factory")).concentratedPoolImplementation();
        address newImpl = address(new ConcentratedPool());
        
        console.log("  Deployed new ConcentratedPool implementation:", newImpl);
        
        upgrades.push(UpgradeInfo({
            proxy: address(0), // No direct proxy for implementation
            oldImplementation: oldImpl,
            newImplementation: newImpl,
            contractName: "ConcentratedPool"
        }));
        
        return newImpl;
    }
    
    /// @notice Deploys new BatchAuction implementation
    function deployNewAuctionImplementation() internal returns (address) {
        address oldImpl = Factory(loadDeploymentAddress("factory")).batchAuctionImplementation();
        address newImpl = address(new BatchAuction());
        
        console.log("  Deployed new BatchAuction implementation:", newImpl);
        
        upgrades.push(UpgradeInfo({
            proxy: address(0),
            oldImplementation: oldImpl,
            newImplementation: newImpl,
            contractName: "BatchAuction"
        }));
        
        return newImpl;
    }
    
    /*//////////////////////////////////////////////////////////////
                        UPGRADE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Upgrades Factory proxy to new implementation
    function upgradeFactory(address proxy, address newImplementation) internal {
        Factory factory = Factory(proxy);
        
        // Upgrade using UUPS
        factory.upgradeToAndCall(newImplementation, "");
        
        console.log("  Factory upgraded to:", newImplementation);
    }
    
    /// @notice Updates implementation addresses in Factory
    function updateImplementations(
        address factoryProxy,
        address newPoolImpl,
        address newAuctionImpl
    ) internal {
        Factory factory = Factory(factoryProxy);
        
        // Update ConcentratedPool implementation
        factory.setImplementation(
            keccak256("ConcentratedPool"),
            newPoolImpl
        );
        console.log("  Updated ConcentratedPool implementation in Factory");
        
        // Update BatchAuction implementation
        factory.setImplementation(
            keccak256("BatchAuction"),
            newAuctionImpl
        );
        console.log("  Updated BatchAuction implementation in Factory");
    }
    
    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Loads deployment address from JSON file
    function loadDeploymentAddress(string memory contractName) internal view returns (address) {
        string memory network = getNetworkName();
        string memory path = string.concat("deployments/", network, ".json");
        
        // Read JSON file
        string memory json = vm.readFile(path);
        
        // Parse address
        string memory key = string.concat(".contracts.", contractName);
        address addr = vm.parseJsonAddress(json, key);
        
        require(addr != address(0), string.concat("Address not found for: ", contractName));
        
        return addr;
    }
    
    /// @notice Prints upgrade summary
    function printUpgradeSummary() internal view {
        console.log("\n==============================================");
        console.log("UPGRADE SUMMARY");
        console.log("==============================================");
        
        for (uint256 i = 0; i < upgrades.length; i++) {
            console.log("\n", upgrades[i].contractName);
            if (upgrades[i].proxy != address(0)) {
                console.log("  Proxy:", upgrades[i].proxy);
            }
            console.log("  Old Implementation:", upgrades[i].oldImplementation);
            console.log("  New Implementation:", upgrades[i].newImplementation);
        }
        
        console.log("\n==============================================");
        console.log("Upgrade complete!");
        console.log("==============================================");
    }
}
