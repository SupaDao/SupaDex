// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IFlashLoanCallback
/// @notice Interface for flash loan callbacks
/// @dev Implement this interface to receive flash loans from ConcentratedPool
interface IFlashLoanCallback {
    /// @notice Called by the pool after transferring tokens for a flash loan
    /// @param token0 Address of token0
    /// @param token1 Address of token1
    /// @param amount0 Amount of token0 borrowed
    /// @param amount1 Amount of token1 borrowed
    /// @param fee0 Fee to be paid for token0
    /// @param fee1 Fee to be paid for token1
    /// @param data Arbitrary data passed from the flash loan caller
    /// @dev The caller must repay amount0 + fee0 and amount1 + fee1 before this function returns
    function flashLoanCallback(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}
