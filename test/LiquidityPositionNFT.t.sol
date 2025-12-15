// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {TestHelper} from "./TestHelper.sol";
import {LiquidityPositionNFT} from "../contracts/periphery/LiquidityPositionNFT.sol";
import {ConcentratedPool} from "../contracts/core/ConcentratedPool.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract LiquidityPositionNFTTest is TestHelper {
    LiquidityPositionNFT nft;
    ConcentratedPool pool;
    MockToken token0;
    MockToken token1;
    
    address user = address(0x1);
    
    function setUp() public {
        token0 = new MockToken("Token0", "TK0");
        token1 = new MockToken("Token1", "TK1");
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        deployFactory();
        pool = createPool(address(token0), address(token1), 3000);
        pool.initializeState(79228162514264337593543950336); // 1:1 price
        
        // Deploy NFT manager
        nft = new LiquidityPositionNFT(address(factory));
        
        // Mint tokens
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        
        // Approve NFT manager
        token0.approve(address(nft), type(uint256).max);
        token1.approve(address(nft), type(uint256).max);
        
        vm.startPrank(user);
        token0.approve(address(nft), type(uint256).max);
        token1.approve(address(nft), type(uint256).max);
        vm.stopPrank();
    }
    
    function testNFT_MintPosition() public {
        LiquidityPositionNFT.MintParams memory params = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, uint256 amount0, uint256 amount1) = nft.mint(params);
        
        assertGt(tokenId, 0, "Token ID should be greater than 0");
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
        assertEq(nft.ownerOf(tokenId), address(this), "Should own the NFT");
    }
    
    function testNFT_IncreaseLiquidity() public {
        // Mint initial position
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        // Get initial liquidity
        (, , , , , uint128 initialLiquidity, , , , ) = nft.positions(tokenId);
        
        // Increase liquidity
        LiquidityPositionNFT.IncreaseLiquidityParams memory increaseParams = LiquidityPositionNFT.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount: 5 ether,
            amount0Max: 50 ether,
            amount1Max: 50 ether,
            deadline: block.timestamp + 1000
        });
        
        (uint256 amount0, uint256 amount1) = nft.increaseLiquidity(increaseParams);
        
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
        
        // Check total liquidity increased
        (, , , , , uint128 totalLiquidity, , , , ) = nft.positions(tokenId);
        assertEq(totalLiquidity, initialLiquidity + 5 ether, "Total liquidity should increase");
    }
    
    function testNFT_DecreaseLiquidity() public {
        // Mint position
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        // Get initial liquidity
        (, , , , , uint128 initialLiquidity, , , , ) = nft.positions(tokenId);
        
        // Decrease liquidity
        uint128 amountToRemove = initialLiquidity / 2;
        LiquidityPositionNFT.DecreaseLiquidityParams memory decreaseParams = LiquidityPositionNFT.DecreaseLiquidityParams({
            tokenId: tokenId,
            amount: amountToRemove,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000
        });
        
        (uint256 amount0, uint256 amount1) = nft.decreaseLiquidity(decreaseParams);
        
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
        
        // Check liquidity decreased
        (, , , , , uint128 remainingLiquidity, , , , ) = nft.positions(tokenId);
        assertEq(remainingLiquidity, initialLiquidity - amountToRemove, "Liquidity should decrease");
    }
    
    function testNFT_Collect() public {
        int24 tickSpacing = 60;
        int24 maxTick = 887220; // Multiple of 60 close to MAX
        int24 minTick = -887220; // Multiple of 60 close to MIN

        // Mint position with full range
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: minTick,
            tickUpper: maxTick,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        assertGt(pool.liquidity(), 0, "Pool liquidity should be > 0 after mint");
        
        // Perform some swaps to generate fees
        token0.mint(address(this), 1 ether);
        token0.approve(address(pool), type(uint256).max);
        
        vm.warp(block.timestamp + 100);
        
        uint256 feeGrowthGlobal0Before = pool.feeGrowthGlobal0X128();
        pool.swap(address(this), true, 1 ether, 4295128740, "");
        uint256 feeGrowthGlobal0After = pool.feeGrowthGlobal0X128();
        
        assertGt(feeGrowthGlobal0After, feeGrowthGlobal0Before, "Fee growth should increase");
        
        // Collect fees
        LiquidityPositionNFT.CollectParams memory collectParams = LiquidityPositionNFT.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        
        uint256 balanceBefore0 = token0.balanceOf(address(this));
        uint256 balanceBefore1 = token1.balanceOf(address(this));
        
        (uint256 amount0, uint256 amount1) = nft.collect(collectParams);
        
        uint256 balanceAfter0 = token0.balanceOf(address(this));
        uint256 balanceAfter1 = token1.balanceOf(address(this));
        
        // Should collect something (fees or principal)
        assertTrue(amount0 > 0 || amount1 > 0, "Should collect some tokens");
        assertEq(balanceAfter0 - balanceBefore0, amount0, "Balance should match collected amount0");
        assertEq(balanceAfter1 - balanceBefore1, amount1, "Balance should match collected amount1");
    }
    
    function testNFT_Burn() public {
        // Mint position
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        // Get liquidity
        (, , , , , uint128 liquidity, , , , ) = nft.positions(tokenId);
        
        // Decrease all liquidity
        LiquidityPositionNFT.DecreaseLiquidityParams memory decreaseParams = LiquidityPositionNFT.DecreaseLiquidityParams({
            tokenId: tokenId,
            amount: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1000
        });
        
        nft.decreaseLiquidity(decreaseParams);
        
        // Collect all tokens
        LiquidityPositionNFT.CollectParams memory collectParams = LiquidityPositionNFT.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        
        nft.collect(collectParams);
        
        // Burn NFT
        nft.burn(tokenId);
        
        // Should revert when trying to get owner of burned token
        vm.expectRevert();
        nft.ownerOf(tokenId);
    }
    
    function testNFT_TokenURI() public {
        // Mint position
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        string memory uri = nft.tokenURI(tokenId);
        
        // Should return a non-empty string
        assertTrue(bytes(uri).length > 0, "Token URI should not be empty");
    }
    
    function testNFT_OnlyOwnerCanModify() public {
        // Mint position
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        // Try to increase liquidity as non-owner
        vm.startPrank(user);
        
        LiquidityPositionNFT.IncreaseLiquidityParams memory increaseParams = LiquidityPositionNFT.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount: 1 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            deadline: block.timestamp + 1000
        });
        
        vm.expectRevert();
        nft.increaseLiquidity(increaseParams);
        
        vm.stopPrank();
    }
    
    function testNFT_Transfer() public {
        // Mint position
        LiquidityPositionNFT.MintParams memory mintParams = LiquidityPositionNFT.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickLower: -600,
            tickUpper: 600,
            amount: 10 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        
        (uint256 tokenId, , ) = nft.mint(mintParams);
        
        // Transfer to user
        nft.transferFrom(address(this), user, tokenId);
        
        assertEq(nft.ownerOf(tokenId), user, "User should own the NFT after transfer");
        
        // User should now be able to modify
        vm.startPrank(user);
        
        LiquidityPositionNFT.IncreaseLiquidityParams memory increaseParams = LiquidityPositionNFT.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount: 1 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            deadline: block.timestamp + 1000
        });
        
        nft.increaseLiquidity(increaseParams);
        
        vm.stopPrank();
    }
}
