// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";

/// @title Config
/// @notice Network-specific configuration for DEX deployment
/// @dev Provides addresses and parameters for different networks
contract Config is Script {
    /*//////////////////////////////////////////////////////////////
                            NETWORK DETECTION
    //////////////////////////////////////////////////////////////*/
    
    enum Network {
        Localhost,
        Sepolia,
        Mainnet,
        Arbitrum,
        Optimism
    }
    
    /// @notice Detects the current network based on chain ID
    /// @return network The detected network
    function getNetwork() public view returns (Network) {
        uint256 chainId = block.chainid;
        
        if (chainId == 31337 || chainId == 1337) return Network.Localhost; // Anvil/Hardhat
        if (chainId == 11155111) return Network.Sepolia;
        if (chainId == 1) return Network.Mainnet;
        if (chainId == 42161) return Network.Arbitrum;
        if (chainId == 10) return Network.Optimism;
        
        revert("Unsupported network");
    }
    
    /*//////////////////////////////////////////////////////////////
                            TOKEN ADDRESSES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Gets WETH address for current network
    function getWETH() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            // Deploy mock WETH on localhost
            return address(0);
        } else if (network == Network.Sepolia) {
            return 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
        } else if (network == Network.Mainnet) {
            return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        } else if (network == Network.Arbitrum) {
            return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        } else if (network == Network.Optimism) {
            return 0x4200000000000000000000000000000000000006;
        }
        
        revert("WETH not configured");
    }
    
    /// @notice Gets USDC address for current network
    function getUSDC() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return address(0);
        } else if (network == Network.Sepolia) {
            return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // USDC on Sepolia
        } else if (network == Network.Mainnet) {
            return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        } else if (network == Network.Arbitrum) {
            return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        } else if (network == Network.Optimism) {
            return 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        }
        
        revert("USDC not configured");
    }
    
    /// @notice Gets USDT address for current network
    function getUSDT() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return address(0);
        } else if (network == Network.Sepolia) {
            return address(0); // No official USDT on Sepolia
        } else if (network == Network.Mainnet) {
            return 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        } else if (network == Network.Arbitrum) {
            return 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        } else if (network == Network.Optimism) {
            return 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
        }
        
        return address(0);
    }
    
    /// @notice Gets DAI address for current network
    function getDAI() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return address(0);
        } else if (network == Network.Sepolia) {
            return 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357; // DAI on Sepolia
        } else if (network == Network.Mainnet) {
            return 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        } else if (network == Network.Arbitrum) {
            return 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        } else if (network == Network.Optimism) {
            return 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        }
        
        return address(0);
    }
    
    /*//////////////////////////////////////////////////////////////
                            FEE TIERS
    //////////////////////////////////////////////////////////////*/
    
    struct FeeTier {
        uint24 fee;
        int24 tickSpacing;
    }
    
    /// @notice Gets all supported fee tiers
    /// @return tiers Array of fee tier configurations
    function getFeeTiers() public pure returns (FeeTier[] memory tiers) {
        tiers = new FeeTier[](3);
        
        // 0.05% fee tier - for stablecoin pairs
        tiers[0] = FeeTier({
            fee: 500,
            tickSpacing: 10
        });
        
        // 0.3% fee tier - for most pairs
        tiers[1] = FeeTier({
            fee: 3000,
            tickSpacing: 60
        });
        
        // 1% fee tier - for exotic pairs
        tiers[2] = FeeTier({
            fee: 10000,
            tickSpacing: 200
        });
    }
    
    /*//////////////////////////////////////////////////////////////
                        BATCH AUCTION PARAMETERS
    //////////////////////////////////////////////////////////////*/
    
    struct BatchAuctionParams {
        uint256 batchDuration;      // Duration in blocks
        uint128 minOrderSize;       // Minimum order size
        uint16 maxPriceDeviationBps; // Max price deviation (basis points)
        uint24 feeBps;              // Fee in basis points
    }
    
    /// @notice Gets batch auction parameters for current network
    function getBatchAuctionParams() public view returns (BatchAuctionParams memory) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            // Faster batches for testing
            return BatchAuctionParams({
                batchDuration: 10,           // 10 blocks (~2 minutes on localhost)
                minOrderSize: 1e15,          // 0.001 tokens
                maxPriceDeviationBps: 1000,  // 10%
                feeBps: 30                   // 0.3%
            });
        } else if (network == Network.Sepolia) {
            return BatchAuctionParams({
                batchDuration: 50,           // 50 blocks (~10 minutes)
                minOrderSize: 1e15,          // 0.001 tokens
                maxPriceDeviationBps: 1000,  // 10%
                feeBps: 30                   // 0.3%
            });
        } else {
            // Mainnet, Arbitrum, Optimism
            return BatchAuctionParams({
                batchDuration: 300,          // 300 blocks (~1 hour on mainnet)
                minOrderSize: 1e16,          // 0.01 tokens
                maxPriceDeviationBps: 500,   // 5%
                feeBps: 30                   // 0.3%
            });
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE PARAMETERS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Gets timelock delay for current network
    /// @return delay Delay in seconds
    function getTimelockDelay() public view returns (uint256 delay) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return 1 hours; // Short delay for testing
        } else if (network == Network.Sepolia) {
            return 6 hours; // Moderate delay for testnet
        } else {
            return 2 days; // Production delay
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT ADDRESSES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Gets deployer address (msg.sender in scripts)
    function getDeployer() public view returns (address) {
        return msg.sender;
    }
    
    /// @notice Gets treasury address for current network
    function getTreasury() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            // Use deployer as treasury on localhost
            return msg.sender;
        } else if (network == Network.Sepolia) {
            // Use deployer as treasury on testnet
            return msg.sender;
        } else {
            // TODO: Replace with actual multisig address for production
            return msg.sender;
        }
    }
    
    /// @notice Gets relayer address for current network
    function getRelayer() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            // Use deployer as relayer on localhost
            return msg.sender;
        } else if (network == Network.Sepolia) {
            // TODO: Replace with actual relayer address
            return msg.sender;
        } else {
            // TODO: Replace with actual relayer address for production
            return msg.sender;
        }
    }
    
    /// @notice Gets pauser/admin address for current network
    function getAdmin() public view returns (address) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            return msg.sender;
        } else if (network == Network.Sepolia) {
            return msg.sender;
        } else {
            // TODO: Replace with actual multisig address for production
            return msg.sender;
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                        INITIAL POOL PAIRS
    //////////////////////////////////////////////////////////////*/
    
    struct PoolPair {
        address token0;
        address token1;
        uint24 fee;
    }
    
    /// @notice Gets initial pool pairs to create on deployment
    /// @return pairs Array of pool pair configurations
    function getInitialPools() public view returns (PoolPair[] memory pairs) {
        address weth = getWETH();
        address usdc = getUSDC();
        address usdt = getUSDT();
        address dai = getDAI();
        
        Network network = getNetwork();
        
        if (network == Network.Localhost) {
            // No initial pools on localhost (tokens need to be deployed first)
            pairs = new PoolPair[](0);
        } else if (usdt == address(0)) {
            // Sepolia - only WETH/USDC and WETH/DAI
            pairs = new PoolPair[](2);
            pairs[0] = PoolPair({token0: weth, token1: usdc, fee: 3000});
            pairs[1] = PoolPair({token0: weth, token1: dai, fee: 3000});
        } else {
            // Mainnet and L2s - full set of pairs
            pairs = new PoolPair[](4);
            pairs[0] = PoolPair({token0: weth, token1: usdc, fee: 3000});
            pairs[1] = PoolPair({token0: weth, token1: usdt, fee: 3000});
            pairs[2] = PoolPair({token0: weth, token1: dai, fee: 3000});
            pairs[3] = PoolPair({token0: usdc, token1: usdt, fee: 500}); // Stablecoin pair
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Gets network name as string
    function getNetworkName() public view returns (string memory) {
        Network network = getNetwork();
        
        if (network == Network.Localhost) return "localhost";
        if (network == Network.Sepolia) return "sepolia";
        if (network == Network.Mainnet) return "mainnet";
        if (network == Network.Arbitrum) return "arbitrum";
        if (network == Network.Optimism) return "optimism";
        
        return "unknown";
    }
    
    /// @notice Checks if current network is a testnet
    function isTestnet() public view returns (bool) {
        Network network = getNetwork();
        return network == Network.Localhost || network == Network.Sepolia;
    }
}
