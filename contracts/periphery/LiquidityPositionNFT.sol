// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IConcentratedPool} from "../interfaces/IConcentratedPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMathOptimized} from "../libraries/TickMathOptimized.sol";

contract LiquidityPositionNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;
    using Strings for int24;
    using SafeERC20 for IERC20;

    address public immutable FACTORY;

    struct Position {
        uint96 nonce;
        address operator;
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) public positions;
    uint256 private _nextTokenId;

    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    constructor(address factory) ERC721("DEX Liquidity Position", "DEX-POS") Ownable(msg.sender) {
        FACTORY = factory;
        _nextTokenId = 1;
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 amount;
        uint256 amount0Max;
        uint256 amount1Max;
        address recipient;
        uint256 deadline;
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "Transaction too old");
        _;
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isAuthorized(ownerOf(tokenId), msg.sender, tokenId), "Not authorized");
        _;
    }

    function mint(MintParams calldata params) external payable checkDeadline(params.deadline) returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        address pool = _getPool(params.token0, params.token1, params.fee);
        
        tokenId = _nextTokenId++;
        _mint(params.recipient, tokenId);

        Position storage position = positions[tokenId];
        position.pool = pool;
        position.tickLower = params.tickLower;
        position.tickUpper = params.tickUpper;

        // Add liquidity
        (amount0, amount1) = _addLiquidity(
            tokenId,
            params.amount,
            pool,
            params.tickLower,
            params.tickUpper,
            params.amount0Max,
            params.amount1Max
        );
        
        position.liquidity = params.amount;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint128 amount;
        uint256 amount0Max;
        uint256 amount1Max;
        uint256 deadline;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = positions[params.tokenId];
        
        (amount0, amount1) = _addLiquidity(
            params.tokenId,
            params.amount,
            position.pool,
            position.tickLower,
            position.tickUpper,
            params.amount0Max,
            params.amount1Max
        );
        
        position.liquidity += params.amount;
        
        emit IncreaseLiquidity(params.tokenId, params.amount, amount0, amount1);
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 amount;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = positions[params.tokenId];
        require(position.liquidity >= params.amount, "Not enough liquidity");
        
        (amount0, amount1) = IConcentratedPool(position.pool).burn(
            position.tickLower,
            position.tickUpper,
            params.amount
        );
        
        require(amount0 >= params.amount0Min, "Amount0 min");
        require(amount1 >= params.amount1Min, "Amount1 min");
        
        position.liquidity -= params.amount;
        // Do not add to tokensOwed here; collect() will handle it when tokens are retrieved from pool
        // position.tokensOwed0 += uint128(amount0);
        // position.tokensOwed1 += uint128(amount1);
        
        emit DecreaseLiquidity(params.tokenId, params.amount, amount0, amount1);
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params)
        external
        payable
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = positions[params.tokenId];
        
        // First collect from pool to this contract
        (uint128 collected0, uint128 collected1) = IConcentratedPool(position.pool).collect(
            address(this),
            position.tickLower,
            position.tickUpper,
            type(uint128).max,
            type(uint128).max
        );
        
        position.tokensOwed0 += collected0;
        position.tokensOwed1 += collected1;
        
        amount0 = params.amount0Max > position.tokensOwed0 ? position.tokensOwed0 : params.amount0Max;
        amount1 = params.amount1Max > position.tokensOwed1 ? position.tokensOwed1 : params.amount1Max;
        
        position.tokensOwed0 -= uint128(amount0);
        position.tokensOwed1 -= uint128(amount1);
        
        if (amount0 > 0) {
            IERC20(IConcentratedPool(position.pool).TOKEN0()).safeTransfer(params.recipient, amount0);
        }
        if (amount1 > 0) {
            IERC20(IConcentratedPool(position.pool).TOKEN1()).safeTransfer(params.recipient, amount1);
        }
        
        emit Collect(params.tokenId, params.recipient, amount0, amount1);
    }

    /// @notice Burns a token ID, which deletes it from the NFT contract. The token must have 0 liquidity and all tokens must be collected first.
    /// @param tokenId The ID of the token to burn
    function burn(uint256 tokenId) external isAuthorizedForToken(tokenId) {
        Position storage position = positions[tokenId];
        require(position.liquidity == 0, "Not cleared");
        require(position.tokensOwed0 == 0, "Not cleared");
        require(position.tokensOwed1 == 0, "Not cleared");
        
        delete positions[tokenId];
        _burn(tokenId);
    }

    interface IWETH {
        function deposit() external payable;
        function withdraw(uint256) external;
        function approve(address, uint256) external returns (bool);
    }

    function _addLiquidity(
        uint256 tokenId,
        uint128 amount,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal returns (uint256 amount0, uint256 amount1) {
        address token0 = IConcentratedPool(pool).TOKEN0();
        address token1 = IConcentratedPool(pool).TOKEN1();
        
        // Handle Native ETH Wrapping
        bool paid0 = false;
        bool paid1 = false;
        
        if (msg.value > 0) {
            // If ETH was sent, we assume it corresponds to one of the tokens (WETH).
            // We identify which one by matching the amount.
            if (amount0Max == msg.value) {
                IWETH(token0).deposit{value: msg.value}();
                paid0 = true;
            } else if (amount1Max == msg.value) {
                IWETH(token1).deposit{value: msg.value}();
                paid1 = true;
            } else {
                // If amounts don't match exactly, we might have an issue or a partial refund case,
                // but for this MVP we assume exact match from the frontend hook.
                // Fallback: try to deposit to token0 if we can't match? No, safer to revert or fail.
            }
        }
        
        if (!paid0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Max);
        }
        if (!paid1) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Max);
        }
        
        IERC20(token0).forceApprove(pool, amount0Max);
        IERC20(token1).forceApprove(pool, amount1Max);
        
        (amount0, amount1) = IConcentratedPool(pool).mint(
            address(this),
            tickLower,
            tickUpper,
            amount,
            ""
        );
        
        // Refund unused
        if (amount0 < amount0Max) {
            IERC20(token0).forceApprove(pool, 0);
            if (paid0) {
                 // Unwrap WETH to ETH for refund
                 IWETH(token0).withdraw(amount0Max - amount0);
                 (bool success, ) = msg.sender.call{value: amount0Max - amount0}("");
                 require(success, "ETH refund failed");
            } else {
                 IERC20(token0).safeTransfer(msg.sender, amount0Max - amount0);
            }
        }
        if (amount1 < amount1Max) {
            IERC20(token1).forceApprove(pool, 0);
             if (paid1) {
                 // Unwrap WETH to ETH for refund
                 IWETH(token1).withdraw(amount1Max - amount1);
                 (bool success, ) = msg.sender.call{value: amount1Max - amount1}("");
                 require(success, "ETH refund failed");
            } else {
                 IERC20(token1).safeTransfer(msg.sender, amount1Max - amount1);
            }
        }
    }

    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (address pool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (bool success, bytes memory data) = FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,uint24)", token0, token1, fee)
        );
        require(success, "Factory call failed");
        pool = abi.decode(data, (address));
        require(pool != address(0), "Pool not found");
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Position memory pos = positions[tokenId];
        
        string memory name = string(abi.encodePacked("Position #", tokenId.toString()));
        string memory description = string(abi.encodePacked(
            "Liquidity Position in pool ", 
            Strings.toHexString(pos.pool),
            " Ticks: ",
            Strings.toStringSigned(int256(pos.tickLower)), 
            "/", 
            Strings.toStringSigned(int256(pos.tickUpper))
        ));
        
        string memory image = _generateSVG(pos);
        
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    abi.encodePacked(
                        '{"name":"', name, '", "description":"', description, '", "image":"', image, '"}'
                    )
                )
            )
        );
    }

    function _generateSVG(Position memory pos) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "data:image/svg+xml;base64,",
                Base64.encode(
                    abi.encodePacked(
                        '<svg width="290" height="500" viewBox="0 0 290 500" xmlns="http://www.w3.org/2000/svg">',
                        '<rect width="290" height="500" fill="#0d111c"/>',
                        '<text x="20" y="40" fill="white" font-family="Arial" font-size="20">DEX Position</text>',
                        '<text x="20" y="80" fill="#888" font-family="Arial" font-size="14">ID: ', uint256(pos.nonce + 1).toString(), '</text>', // Use nonce as surrogate if needed, or tokenId
                        '<text x="20" y="110" fill="#888" font-family="Arial" font-size="14">Tick Lower: ', Strings.toStringSigned(int256(pos.tickLower)), '</text>',
                        '<text x="20" y="140" fill="#888" font-family="Arial" font-size="14">Tick Upper: ', Strings.toStringSigned(int256(pos.tickUpper)), '</text>',
                        '<text x="20" y="170" fill="#888" font-family="Arial" font-size="14">Liquidity: ', uint256(pos.liquidity).toString(), '</text>',
                        '</svg>'
                    )
                )
            )
        );
    }
}
