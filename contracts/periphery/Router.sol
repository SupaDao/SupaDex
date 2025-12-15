// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IConcentratedPool} from "../interfaces/IConcentratedPool.sol";
import {IConcentratedPoolSwapCallback} from "../interfaces/IConcentratedPoolSwapCallback.sol";
import {Path} from "../libraries/Path.sol";
import {TickMathOptimized} from "../libraries/TickMathOptimized.sol";

contract Router is IConcentratedPoolSwapCallback {
    using SafeERC20 for IERC20;
    using Path for bytes;
    
    address public immutable FACTORY;

    constructor(address _factory) {
        FACTORY = _factory;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        uint256 deadline;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
        uint256 deadline;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint256 deadline;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint256 deadline;
    }

    struct CallbackData {
        bytes path;
        address payer;
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "Transaction too old");
        _;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        amountOut = exactInput(ExactInputParams({
            path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut),
            recipient: params.recipient,
            amountIn: params.amountIn,
            amountOutMinimum: params.amountOutMinimum,
            deadline: params.deadline
        }));
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        amountIn = exactOutput(ExactOutputParams({
            path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn),
            recipient: params.recipient,
            amountOut: params.amountOut,
            amountInMaximum: params.amountInMaximum,
            deadline: params.deadline
        }));
    }

    function exactInput(ExactInputParams memory params)
        public
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        address payer = msg.sender;
        bytes memory path = params.path;
        uint256 amountIn = params.amountIn;
        
        while (true) {
            bool hasMultiplePools = path.hasMultiplePoolsMemory();
            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPoolMemory();
            
            address pool = _getPool(tokenIn, tokenOut, fee);
            
            // Transfer to router if first hop and payer is user
            if (payer == msg.sender) {
                IERC20(tokenIn).safeTransferFrom(payer, address(this), amountIn);
                payer = address(this);
            }
            IERC20(tokenIn).forceApprove(pool, amountIn);
            
            bool zeroForOne = tokenIn < tokenOut;
            address recipient = hasMultiplePools ? address(this) : params.recipient;
            
            (int256 amount0, int256 amount1) = IConcentratedPool(pool).swap(
                recipient,
                zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                int256(amountIn),
                zeroForOne ? TickMathOptimized.MIN_SQRT_RATIO + 1 : TickMathOptimized.MAX_SQRT_RATIO - 1,
                abi.encode(CallbackData({
                    path: abi.encodePacked(tokenOut, fee, tokenIn), // Just this hop (reversed for callback)
                    payer: payer
                }))
            );
            
            // forge-lint: disable-next-line(unsafe-typecast)
            amountOut = zeroForOne ? uint256(-amount1) : uint256(-amount0);
            
            if (hasMultiplePools) {
                path = path.skipTokenMemory();
                amountIn = amountOut;
            } else {
                break;
            }
        }
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    function exactOutput(ExactOutputParams memory params)
        public
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // Path: [tokenOut, fee, tokenIn, fee, tokenPrev...]
        (address tokenOut, address tokenIn, uint24 fee) = params.path.decodeFirstPoolMemory();
        
        address pool = _getPool(tokenIn, tokenOut, fee);
        bool zeroForOne = tokenIn < tokenOut;
        
        (int256 amount0, int256 amount1) = IConcentratedPool(pool).swap(
            params.recipient,
            zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            -int256(params.amountOut),
            zeroForOne ? TickMathOptimized.MIN_SQRT_RATIO + 1 : TickMathOptimized.MAX_SQRT_RATIO - 1,
            abi.encode(CallbackData({
                path: params.path, // Full path for recursion
                payer: msg.sender
            }))
        );
        
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = zeroForOne ? uint256(amount0) : uint256(amount1);
        require(amountIn <= params.amountInMaximum, "Too much requested");
        
        // Refund if we pulled too much (only if not multihop, but multihop exactOutput handles exact amounts recursively)
        // Actually, with exactOutput, the router pulls exactly what's needed in the callback.
        // But for the FIRST hop (last in chain), which is this execution, the callback might pull more if there is slippage? 
        // No, swap logic determines input amount.
        
    }

    function concentratedPoolSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0, "Invalid callback");
        
        CallbackData memory decoded = abi.decode(data, (CallbackData));
        (address tokenOut, address tokenIn, uint24 fee) = decoded.path.decodeFirstPoolMemory();
        address pool = _getPool(tokenIn, tokenOut, fee);
        require(msg.sender == pool, "Not pool");
        
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        
        if (decoded.path.hasMultiplePoolsMemory()) {
            // Recursive exactOutput case
            decoded.path = decoded.path.skipTokenMemory();
            (address nextTokenOut, address nextTokenIn, uint24 nextFee) = decoded.path.decodeFirstPoolMemory();
            address nextPool = _getPool(nextTokenIn, nextTokenOut, nextFee);
            bool zeroForOne = nextTokenIn < nextTokenOut;
            
            // Recursive call to get the tokens needed to pay this pool
            IConcentratedPool(nextPool).swap(
                msg.sender, // Pay outcome to current pool
                zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                -int256(amountToPay),
                zeroForOne ? TickMathOptimized.MIN_SQRT_RATIO + 1 : TickMathOptimized.MAX_SQRT_RATIO - 1,
                abi.encode(decoded)
            );
        } else {
            // Terminal case (source of funds)
            if (decoded.payer == address(this)) {
                // If router is payer, we just pay
                IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
            } else {
                // Determine if we are pulling from user
                 IERC20(tokenIn).safeTransferFrom(decoded.payer, msg.sender, amountToPay);
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
}
