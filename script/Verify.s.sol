// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Config} from "./Config.s.sol";

/// @title Verify
/// @notice Script for generating contract verification commands
/// @dev Reads deployment manifest and outputs verification commands for Etherscan
contract Verify is Script, Config {
    /*//////////////////////////////////////////////////////////////
                        VERIFICATION COMMANDS
    //////////////////////////////////////////////////////////////*/
    
    function run() external view {
        console.log("==============================================");
        console.log("Contract Verification Commands");
        console.log("==============================================");
        console.log("Network:", getNetworkName());
        console.log("==============================================\n");
        
        // Load deployment addresses
        string memory network = getNetworkName();
        string memory path = string.concat("deployments/", network, ".json");
        string memory json = vm.readFile(path);
        
        // Parse addresses
        address factory = vm.parseJsonAddress(json, ".contracts.factory");
        address factoryImpl = vm.parseJsonAddress(json, ".contracts.factoryImpl");
        address poolImpl = vm.parseJsonAddress(json, ".contracts.concentratedPoolImpl");
        address auctionImpl = vm.parseJsonAddress(json, ".contracts.batchAuctionImpl");
        address treasury = vm.parseJsonAddress(json, ".contracts.treasury");
        address router = vm.parseJsonAddress(json, ".contracts.router");
        address positionNFT = vm.parseJsonAddress(json, ".contracts.positionNFT");
        address timelock = vm.parseJsonAddress(json, ".contracts.timelock");
        
        // Get explorer URL
        string memory explorerUrl = getExplorerUrl();
        string memory apiUrl = getExplorerApiUrl();
        
        console.log("Explorer:", explorerUrl);
        console.log("API URL:", apiUrl);
        console.log("\n==============================================");
        console.log("VERIFICATION COMMANDS");
        console.log("==============================================\n");
        
        // Factory Implementation
        console.log("# Factory Implementation");
        printVerifyCommand("Factory", factoryImpl, "");
        
        // ConcentratedPool Implementation
        console.log("\n# ConcentratedPool Implementation");
        printVerifyCommand("ConcentratedPool", poolImpl, "");
        
        // BatchAuction Implementation
        console.log("\n# BatchAuction Implementation");
        printVerifyCommand("BatchAuction", auctionImpl, "");
        
        // Router
        console.log("\n# Router");
        string memory routerArgs = string.concat("--constructor-args $(cast abi-encode 'constructor(address)' ", vm.toString(factory), ")");
        printVerifyCommand("Router", router, routerArgs);
        
        // TreasuryAndFees
        console.log("\n# TreasuryAndFees");
        printVerifyCommand("TreasuryAndFees", treasury, "");
        
        // LiquidityPositionNFT
        console.log("\n# LiquidityPositionNFT");
        printVerifyCommand("LiquidityPositionNFT", positionNFT, "");
        
        // GovernanceTimelock
        console.log("\n# GovernanceTimelock");
        uint256 timelockDelay = getTimelockDelay();
        address admin = getAdmin();
        string memory timelockArgs = string.concat(
            "--constructor-args $(cast abi-encode 'constructor(uint256,address)' ",
            vm.toString(timelockDelay),
            " ",
            vm.toString(admin),
            ")"
        );
        printVerifyCommand("GovernanceTimelock", timelock, timelockArgs);
        
        // Factory Proxy
        console.log("\n# Factory Proxy (ERC1967Proxy)");
        console.log("# Note: Proxy verification requires manual verification on Etherscan");
        console.log("# 1. Go to:", string.concat(explorerUrl, "/address/", vm.toString(factory), "#code"));
        console.log("# 2. Click 'More Options' -> 'Is this a proxy?'");
        console.log("# 3. Verify the proxy");
        
        console.log("\n==============================================");
        console.log("BATCH VERIFICATION");
        console.log("==============================================\n");
        
        console.log("# Verify all contracts at once:");
        console.log("forge verify-contract --chain", getNetworkName(), "--watch \\");
        console.log("  ", vm.toString(factoryImpl), "contracts/core/Factory.sol:Factory && \\");
        console.log("forge verify-contract --chain", getNetworkName(), "--watch \\");
        console.log("  ", vm.toString(poolImpl), "contracts/core/ConcentratedPool.sol:ConcentratedPool && \\");
        console.log("forge verify-contract --chain", getNetworkName(), "--watch \\");
        console.log("  ", vm.toString(auctionImpl), "contracts/core/BatchAuction.sol:BatchAuction && \\");
        console.log("forge verify-contract --chain", getNetworkName(), "--watch \\");
        console.log("  ", vm.toString(router), "contracts/periphery/Router.sol:Router", routerArgs);
        
        console.log("\n==============================================");
    }
    
    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Prints verification command for a contract
    function printVerifyCommand(
        string memory contractName,
        address contractAddress,
        string memory constructorArgs
    ) internal view {
        string memory contractPath = getContractPath(contractName);
        
        console.log("forge verify-contract \\");
        console.log("  --chain", getNetworkName(), "\\");
        console.log("  --watch \\");
        
        if (bytes(constructorArgs).length > 0) {
            console.log(" ", constructorArgs, "\\");
        }
        
        console.log("  ", vm.toString(contractAddress), "\\");
        console.log("  ", contractPath);
    }
    
    /// @notice Gets contract path for verification
    function getContractPath(string memory contractName) internal pure returns (string memory) {
        if (keccak256(bytes(contractName)) == keccak256("Factory")) {
            return "contracts/core/Factory.sol:Factory";
        } else if (keccak256(bytes(contractName)) == keccak256("ConcentratedPool")) {
            return "contracts/core/ConcentratedPool.sol:ConcentratedPool";
        } else if (keccak256(bytes(contractName)) == keccak256("BatchAuction")) {
            return "contracts/core/BatchAuction.sol:BatchAuction";
        } else if (keccak256(bytes(contractName)) == keccak256("Router")) {
            return "contracts/periphery/Router.sol:Router";
        } else if (keccak256(bytes(contractName)) == keccak256("TreasuryAndFees")) {
            return "contracts/core/TreasuryAndFees.sol:TreasuryAndFees";
        } else if (keccak256(bytes(contractName)) == keccak256("LiquidityPositionNFT")) {
            return "contracts/periphery/LiquidityPositionNFT.sol:LiquidityPositionNFT";
        } else if (keccak256(bytes(contractName)) == keccak256("GovernanceTimelock")) {
            return "contracts/governance/GovernanceTimelock.sol:GovernanceTimelock";
        }
        
        return "";
    }
    
    /// @notice Gets block explorer URL for current network
    function getExplorerUrl() internal view returns (string memory) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return "http://localhost:8545";
        } else if (network == Network.Sepolia) {
            return "https://sepolia.etherscan.io";
        } else if (network == Network.Mainnet) {
            return "https://etherscan.io";
        } else if (network == Network.Arbitrum) {
            return "https://arbiscan.io";
        } else if (network == Network.Optimism) {
            return "https://optimistic.etherscan.io";
        }
        
        return "";
    }
    
    /// @notice Gets block explorer API URL for current network
    function getExplorerApiUrl() internal view returns (string memory) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return "http://localhost:8545";
        } else if (network == Network.Sepolia) {
            return "https://api-sepolia.etherscan.io/api";
        } else if (network == Network.Mainnet) {
            return "https://api.etherscan.io/api";
        } else if (network == Network.Arbitrum) {
            return "https://api.arbiscan.io/api";
        } else if (network == Network.Optimism) {
            return "https://api-optimistic.etherscan.io/api";
        }
        
        return "";
    }
}
