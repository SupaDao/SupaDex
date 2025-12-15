// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title LiquidityMath
/// @notice Math for computing liquidity
library LiquidityMath {
    /// @notice Add a signed liquidity delta to liquidity and revert if it overflows or underflows
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            require((z = x - uint128(-y)) < x, "LS");
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            require((z = x + uint128(y)) >= x, "LA");
        }
    }
}
