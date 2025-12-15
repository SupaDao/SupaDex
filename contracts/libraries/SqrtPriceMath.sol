// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FullMath} from "./FullMath.sol";

/// @title SqrtPriceMath
/// @notice Functions for computing sqrt prices and amounts
library SqrtPriceMath {
    using FullMath for uint256;

    /// @notice Gets the next sqrt price given a delta of token0
    function getNextSqrtPriceFromAmount0RoundingUp(
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << 96;

        if (add) {
            uint256 product;
            if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1)
                    return uint160(numerator1.mulDivRoundingUp(sqrtPX96, denominator));
            }

            return uint160(numerator1.mulDivRoundingUp(1, numerator1 / sqrtPX96 + amount));
        } else {
            uint256 product;
            // if the product overflows, we know the denominator underflows
            // in addition, we must check that the denominator does not underflow
            require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
            uint256 denominator = numerator1 - product;
            return uint160(numerator1.mulDivRoundingUp(sqrtPX96, denominator));
        }
    }

    /// @notice Gets the next sqrt price given a delta of token1
    function getNextSqrtPriceFromAmount1RoundingDown(
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (add) {
            uint256 quotient = (amount <= type(uint160).max)
                ? (amount << 96) / liquidity
                : amount.mulDiv(1 << 96, liquidity);

            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(uint256(sqrtPX96) + quotient);
        } else {
            uint256 quotient = (amount <= type(uint160).max)
                ? (amount << 96) / liquidity + 1 // round up
                : amount.mulDivRoundingUp(1 << 96, liquidity);

            require(uint256(sqrtPX96) > quotient);
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(uint256(sqrtPX96) - quotient);
        }
    }

    /// @notice Gets the amount0 delta between two prices
    function getAmount0Delta(
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioAX96,
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 numerator1 = uint256(liquidity) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        if (roundUp) {
            amount0 = FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96);
            amount0 = FullMath.mulDivRoundingUp(amount0, 1, sqrtRatioAX96);
        } else {
            amount0 = FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96);
            amount0 = FullMath.mulDiv(amount0, 1, sqrtRatioAX96);
        }
    }

    /// @notice Gets the amount0 delta between two prices (signed)
    function getAmount0Delta(
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioAX96,
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) internal pure returns (int256 amount0) {
        amount0 = liquidity < 0
            // forge-lint: disable-next-line(unsafe-typecast)
            ? -int256(getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false))
            // forge-lint: disable-next-line(unsafe-typecast)
            : int256(getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true));
    }

    /// @notice Gets the amount1 delta between two prices
    function getAmount1Delta(
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioAX96,
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (roundUp) {
            amount1 = FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
        } else {
            amount1 = FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
        }
    }

    /// @notice Gets the amount1 delta between two prices (signed)
    function getAmount1Delta(
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioAX96,
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) internal pure returns (int256 amount1) {
        amount1 = liquidity < 0
            // forge-lint: disable-next-line(unsafe-typecast)
            ? -int256(getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false))
            // forge-lint: disable-next-line(unsafe-typecast)
            : int256(getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true));
    }
}
