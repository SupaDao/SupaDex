// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IConcentratedPool} from "../interfaces/IConcentratedPool.sol";

/// @title TreasuryAndFees
/// @notice Manages protocol fees collection and distribution
contract TreasuryAndFees is Ownable {
    using SafeERC20 for IERC20;

    event FeesCollected(address indexed pool, address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event FeeProtocolUpdated(address indexed pool, uint8 oldFeeProtocol, uint8 newFeeProtocol);

    address public feeRecipient;

    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);

    constructor() Ownable(msg.sender) {
        feeRecipient = msg.sender;
    }

    /// @notice Sets the default fee recipient
    /// @param _feeRecipient The new fee recipient address
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid recipient");
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    /// @notice Sets the protocol fee for a pool
    /// @param pool The pool address
    /// @param feeProtocol The protocol fee denominator (0 = no fee, 4-10 = 1/4 to 1/10 of swap fees)
    function setPoolFeeProtocol(address pool, uint8 feeProtocol) external onlyOwner {
        IConcentratedPool(pool).setFeeProtocol(feeProtocol);
    }

    /// @notice Collects protocol fees from a pool
    /// @param pool The pool address
    /// @param recipient The recipient of the fees
    /// @param amount0Requested Amount of token0 to collect
    /// @param amount1Requested Amount of token1 to collect
    /// @return amount0 Amount of token0 collected
    /// @return amount1 Amount of token1 collected
    function collectPoolFees(
        address pool,
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external onlyOwner returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = IConcentratedPool(pool).collectProtocol(
            recipient,
            amount0Requested,
            amount1Requested
        );

        if (amount0 > 0) {
            emit FeesCollected(pool, IConcentratedPool(pool).TOKEN0(), amount0);
        }
        if (amount1 > 0) {
            emit FeesCollected(pool, IConcentratedPool(pool).TOKEN1(), amount1);
        }
    }

    /// @notice Withdraws tokens from the treasury
    /// @param token The token address
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function withdraw(address token, address recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(recipient, amount);
        emit FeesWithdrawn(token, recipient, amount);
    }

    /// @notice Emergency function to recover stuck tokens
    /// @param token The token address
    /// @param recipient The recipient address
    function emergencyWithdraw(address token, address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
            emit FeesWithdrawn(token, recipient, balance);
        }
    }

    /// @notice Returns the balance of a token in the treasury
    /// @param token The token address
    /// @return The balance
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
