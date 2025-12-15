// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IConcentratedPool} from "../interfaces/IConcentratedPool.sol";
import {TickMathOptimized} from "../libraries/TickMathOptimized.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OracleGuard
/// @notice Protects against price manipulation using TWAP
contract OracleGuard is Pausable, Ownable {
    error PriceDeviationTooHigh(int24 deviation, uint256 maxDeviation);
    error InvalidSecondsAgo();
    error OracleStale();

    constructor() Ownable(msg.sender) {}

    function setPaused(bool _paused) external onlyOwner {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    /// @notice Returns the time-weighted average tick
    /// @param pool The pool to query
    /// @param secondsAgo How far back to look
    /// @return tick The time-weighted average tick
    function getTwapTick(address pool, uint32 secondsAgo) public view whenNotPaused returns (int24 tick) {
        if (secondsAgo == 0) revert InvalidSecondsAgo();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IConcentratedPool(pool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        
        tick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
        
        // Rounding
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) {
            tick--;
        }
    }

    /// @notice Checks if the current price deviates too much from the TWAP
    /// @param pool The pool to check
    /// @param secondsAgo The TWAP duration
    /// @param maxDeviationBps The maximum allowed deviation in basis points (1 tick ~= 1 bps)
    function checkDeviation(address pool, uint32 secondsAgo, uint256 maxDeviationBps) external view whenNotPaused {
        (, int24 currentTick, , , , , ) = IConcentratedPool(pool).slot0();
        int24 twapTick = getTwapTick(pool, secondsAgo);
        
        int24 deviation = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
        
        // Convert tick deviation to price deviation approximation
        // 1 tick is 0.01% (1 basis point)
        // So deviation in ticks is roughly deviation in BPS
        if (uint256(int256(deviation)) > maxDeviationBps) {
            revert PriceDeviationTooHigh(deviation, maxDeviationBps);
        }
    }

    /// @notice Gets the quote amount for a given input amount using TWAP
    /// @param pool The pool to query
    /// @param amountIn The input amount
    /// @param tokenIn The input token
    /// @param secondsAgo The TWAP duration
    /// @return amountOut The output amount
    function getQuoteAtTick(
        address pool,
        uint128 amountIn,
        address tokenIn,
        uint32 secondsAgo
    ) external view whenNotPaused returns (uint256 amountOut) {
        int24 tick = getTwapTick(pool, secondsAgo);
        uint160 sqrtPriceX96 = TickMathOptimized.getSqrtRatioAtTick(tick);

        address token0 = IConcentratedPool(pool).TOKEN0();
        address token1 = IConcentratedPool(pool).TOKEN1();

        if (tokenIn == token0) {
            // Calculate amount1 (tokenOut) given amount0 (tokenIn)
            // amount1 = amount0 * price
            // price = sqrtPrice^2
            // amount1 = amount0 * (sqrtPriceX96 / 2^96)^2
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            amountOut = FullMath.mulDiv(ratioX192, amountIn, 1 << 192);
        } else {
            require(tokenIn == token1, "Invalid token");
            // Calculate amount0 (tokenOut) given amount1 (tokenIn)
            // amount0 = amount1 / price
            // amount0 = amount1 / (sqrtPriceX96 / 2^96)^2
            // amount0 = amount1 * 2^192 / sqrtPriceX96^2
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            amountOut = FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        }
    }
}
