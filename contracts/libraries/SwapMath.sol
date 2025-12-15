// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FullMath} from "./FullMath.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";

/// @title Computes the result of a swap within one tick
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            
            if (amountRemainingLessFee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = zeroForOne
                    ? SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(
                        sqrtRatioCurrentX96,
                        liquidity,
                        amountRemainingLessFee,
                        true
                    )
                    : SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(
                        sqrtRatioCurrentX96,
                        liquidity,
                        amountRemainingLessFee,
                        true
                    );
            }
        } else {
            // Exact output
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            
            // forge-lint: disable-next-line(unsafe-typecast)
            if (uint256(-amountRemaining) >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = zeroForOne
                    ? SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(
                        sqrtRatioCurrentX96,
                        liquidity,
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint256(-amountRemaining),
                        false
                    )
                    : SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(
                        sqrtRatioCurrentX96,
                        liquidity,
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint256(-amountRemaining),
                        false
                    );
            }
        }

        // Recompute amounts
        bool max = sqrtRatioNextX96 == sqrtRatioTargetX96;
        
        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            amountOut = uint256(-amountRemaining);
        }

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // forge-lint: disable-next-line(unsafe-typecast)
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
