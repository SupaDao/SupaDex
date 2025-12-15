// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Callback for IConcentratedPoolActions#swap
/// @notice Any contract that calls IConcentratedPoolActions#swap must implement this interface
interface IConcentratedPoolSwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IConcentratedPool#swap.
    /// @dev In the implementation you must pay the pool the tokens owed for the swap.
    /// The caller of this method must be checked to be a ConcentratedPool deployed by the canonical Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IConcentratedPoolActions#swap call
    function concentratedPoolSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
