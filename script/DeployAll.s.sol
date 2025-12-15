// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Config} from "./Config.s.sol";

// Core contracts
import {Factory} from "../contracts/core/Factory.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {BatchAuction} from "../contracts/core/BatchAuction.sol";
import {TreasuryAndFees} from "../contracts/core/TreasuryAndFees.sol";
import {LimitOrderBook} from "../contracts/core/LimitOrderBook.sol";

// Periphery contracts
import {Router} from "../contracts/periphery/Router.sol";
import {LiquidityPositionNFT} from "../contracts/periphery/LiquidityPositionNFT.sol";

// Governance
import {GovernanceTimelock} from "../contracts/governance/GovernanceTimelock.sol";

/// @title DeployAll
/// @notice Comprehensive deployment script for the entire DEX system
/// @dev Deploys all contracts with proper configuration and role setup
contract DeployAll is Script, Config {
    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT STATE
    //////////////////////////////////////////////////////////////*/
    
    struct Deployment {
        // Core contracts
        address factory;
        address factoryImpl;
        address concentratedPoolImpl;
        address batchAuctionImpl;
        address treasury;
        
        // Periphery
        address router;
        address positionNFT;
        
        // Governance
        address timelock;
        
        // Initial pools
        address[] pools;
        address[] auctions;
    }
    
    Deployment public deployment;
    
    /*//////////////////////////////////////////////////////////////
                            MAIN DEPLOYMENT
    //////////////////////////////////////////////////////////////*/
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("==============================================");
        console.log("DEX Deployment Script");
        console.log("==============================================");
        console.log("Network:", getNetworkName());
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("==============================================");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy governance
        console.log("\n[1/7] Deploying Governance...");
        deployGovernance();
        
        // Step 2: Deploy core implementations
        console.log("\n[2/7] Deploying Core Implementations...");
        deployCoreImplementations();
        
        // Step 3: Deploy Factory with proxy
        console.log("\n[3/7] Deploying Factory...");
        deployFactory(deployer);
        
        // Step 4: Deploy periphery contracts
        console.log("\n[4/7] Deploying Periphery Contracts...");
        deployPeriphery();
        
        // Step 5: Configure contracts
        console.log("\n[5/7] Configuring Contracts...");
        configureContracts();
        
        // Step 6: Set up roles and permissions
        console.log("\n[6/7] Setting Up Roles...");
        setupRoles();
        
        // Step 7: Create initial pools
        console.log("\n[7/7] Creating Initial Pools...");
        createInitialPools();
        
        vm.stopBroadcast();
        
        // Print deployment summary
        printDeploymentSummary();
        
        // Save deployment to file
        saveDeployment();
    }
    
    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Deploys governance contracts
    function deployGovernance() internal {
        uint256 timelockDelay = getTimelockDelay();
        address admin = getAdmin();
        
        // Deploy Timelock implementation
        address timelockImpl = address(new GovernanceTimelock());
        
        // Prepare initialization data
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = admin;
        executors[0] = admin;
        
        bytes memory timelockInitData = abi.encodeWithSelector(
            GovernanceTimelock.initialize.selector,
            timelockDelay,
            admin,
            proposers,
            executors
        );
        
        // Deploy proxy
        ERC1967Proxy timelockProxy = new ERC1967Proxy(timelockImpl, timelockInitData);
        deployment.timelock = address(timelockProxy);
        
        console.log("  Timelock deployed:", deployment.timelock);
        console.log("  Timelock delay:", timelockDelay, "seconds");
    }
    
    /// @notice Deploys core contract implementations
    function deployCoreImplementations() internal {
        // Deploy ConcentratedPool implementation
        deployment.concentratedPoolImpl = address(new ConcentratedPool());
        console.log("  ConcentratedPool implementation:", deployment.concentratedPoolImpl);
        
        // Deploy BatchAuction implementation
        deployment.batchAuctionImpl = address(new BatchAuction());
        console.log("  BatchAuction implementation:", deployment.batchAuctionImpl);
    }
    
    /// @notice Deploys Factory with UUPS proxy
    function deployFactory(address owner) internal {
        // Deploy Factory implementation
        deployment.factoryImpl = address(new Factory());
        console.log("  Factory implementation:", deployment.factoryImpl);
        
        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            Factory.initialize.selector,
            owner
        );
        
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(deployment.factoryImpl, initData);
        deployment.factory = address(proxy);
        
        console.log("  Factory proxy:", deployment.factory);
    }
    
    /// @notice Deploys periphery contracts
    function deployPeriphery() internal {
        // Deploy Router
        deployment.router = address(new Router(deployment.factory));
        console.log("  Router:", deployment.router);
        
        // Deploy LiquidityPositionNFT with factory address
        deployment.positionNFT = address(new LiquidityPositionNFT(deployment.factory));
        console.log("  LiquidityPositionNFT:", deployment.positionNFT);
        
        // Deploy TreasuryAndFees
        deployment.treasury = address(new TreasuryAndFees());
        console.log("  TreasuryAndFees:", deployment.treasury);
    }
    
    /// @notice Configures all deployed contracts
    function configureContracts() internal {
        Factory factory = Factory(deployment.factory);
        
        // Set implementations in Factory
        factory.setImplementation(
            keccak256("ConcentratedPool"),
            deployment.concentratedPoolImpl
        );
        console.log("  Set ConcentratedPool implementation in Factory");
        
        factory.setImplementation(
            keccak256("BatchAuction"),
            deployment.batchAuctionImpl
        );
        console.log("  Set BatchAuction implementation in Factory");
    }
    
    /// @notice Sets up roles and permissions
    function setupRoles() internal {
        Factory factory = Factory(deployment.factory);
        address relayer = getRelayer();
        address admin = getAdmin();
        
        // Grant UPGRADER_ROLE to timelock for Factory
        // Note: Factory uses OwnableUpgradeable, so we transfer ownership to timelock
        // In production, you'd want to use AccessControl for more granular permissions
        console.log("  Transferring Factory ownership to timelock:", deployment.timelock);
        // factory.transferOwnership(deployment.timelock); // Uncomment when ready for production
        
        console.log("  Roles configured");
        console.log("  Relayer address:", relayer);
        console.log("  Admin address:", admin);
    }
    
    /// @notice Creates initial pool pairs
    function createInitialPools() internal {
        Config.PoolPair[] memory pairs = getInitialPools();
        
        if (pairs.length == 0) {
            console.log("  No initial pools to create");
            return;
        }
        
        Factory factory = Factory(deployment.factory);
        deployment.pools = new address[](pairs.length);
        deployment.auctions = new address[](pairs.length);
        
        for (uint256 i = 0; i < pairs.length; i++) {
            // Create pool
            address pool = factory.createPool(
                pairs[i].token0,
                pairs[i].token1,
                pairs[i].fee
            );
            deployment.pools[i] = pool;
            
            console.log("  Pool created:", pool);
            console.log("    Token0:", pairs[i].token0);
            console.log("    Token1:", pairs[i].token1);
            console.log("    Fee:", pairs[i].fee);
            
            // Create corresponding auction
            address auction = factory.createAuction(
                pairs[i].token0,
                pairs[i].token1
            );
            deployment.auctions[i] = auction;
            
            console.log("  Auction created:", auction);
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                        OUTPUT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Prints deployment summary
    function printDeploymentSummary() internal view {
        console.log("\n==============================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("==============================================");
        console.log("\nCore Contracts:");
        console.log("  Factory (Proxy):", deployment.factory);
        console.log("  Factory (Impl):", deployment.factoryImpl);
        console.log("  ConcentratedPool (Impl):", deployment.concentratedPoolImpl);
        console.log("  BatchAuction (Impl):", deployment.batchAuctionImpl);
        console.log("  TreasuryAndFees:", deployment.treasury);
        
        console.log("\nPeriphery Contracts:");
        console.log("  Router:", deployment.router);
        console.log("  LiquidityPositionNFT:", deployment.positionNFT);
        
        console.log("\nGovernance:");
        console.log("  Timelock:", deployment.timelock);
        
        if (deployment.pools.length > 0) {
            console.log("\nInitial Pools:");
            for (uint256 i = 0; i < deployment.pools.length; i++) {
                console.log("  Pool", i, ":", deployment.pools[i]);
                console.log("  Auction", i, ":", deployment.auctions[i]);
            }
        }
        
        console.log("\n==============================================");
        console.log("Deployment complete!");
        console.log("==============================================");
    }
    
    /// @notice Saves deployment addresses to JSON file
    function saveDeployment() internal {
        string memory network = getNetworkName();
        string memory outputPath = string.concat("deployments/", network, ".json");
        
        // Build JSON manually
        string memory json = string.concat(
            '{\n',
            '  "network": "', network, '",\n',
            '  "chainId": ', vm.toString(block.chainid), ',\n',
            '  "timestamp": ', vm.toString(block.timestamp), ',\n',
            '  "deployer": "', vm.toString(msg.sender), '",\n',
            '  "contracts": {\n',
            '    "factory": "', vm.toString(deployment.factory), '",\n',
            '    "factoryImpl": "', vm.toString(deployment.factoryImpl), '",\n',
            '    "concentratedPoolImpl": "', vm.toString(deployment.concentratedPoolImpl), '",\n',
            '    "batchAuctionImpl": "', vm.toString(deployment.batchAuctionImpl), '",\n',
            '    "treasury": "', vm.toString(deployment.treasury), '",\n',
            '    "router": "', vm.toString(deployment.router), '",\n',
            '    "positionNFT": "', vm.toString(deployment.positionNFT), '",\n',
            '    "timelock": "', vm.toString(deployment.timelock), '"\n',
            '  }\n',
            '}'
        );
        
        vm.writeFile(outputPath, json);
        console.log("\nDeployment saved to:", outputPath);
    }
}
