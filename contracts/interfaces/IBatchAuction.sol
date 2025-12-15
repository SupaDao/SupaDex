// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IBatchAuction
/// @notice Interface for the batch auction contract
interface IBatchAuction {
    
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Order structure
    struct Order {
        uint64 nonce;
        uint64 expiry;
        uint128 amount;
        uint128 limitPrice;
        uint8 side; // 0 = buy, 1 = sell
    }
    
    /// @notice Batch state enumeration
    enum BatchState { Open, Revealing, Settled }
    
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Emitted when a commitment is submitted
    event CommitmentSubmitted(address indexed user, bytes32 commitment, uint256 batchId);
    
    /// @notice Emitted when an order is revealed
    event OrderRevealed(address indexed user, bytes32 commitment, uint256 batchId);
    
    /// @notice Emitted when a batch is settled
    event BatchSettled(uint256 indexed batchId, uint256 clearingPrice, uint256 totalVolume);
    
    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Commits to an order
    /// @param commitment Hash of order + salt
    function commitOrder(bytes32 commitment) external;
    
    /// @notice Reveals an order
    /// @param order The order details
    /// @param salt The salt used in commitment
    function revealOrder(Order calldata order, bytes32 salt) external;
    
    /// @notice Settles a batch (legacy)
    /// @param batchId The batch ID
    /// @param clearingPrice The clearing price
    /// @param ordersRoot The merkle root
    function settleBatch(uint256 batchId, uint256 clearingPrice, bytes32 ordersRoot) external;
    
    /// @notice Gets current batch ID
    /// @return batchId The current batch ID
    function getCurrentBatchId() external view returns (uint256 batchId);
    
    /// @notice Gets batch state
    /// @param batchId The batch ID
    /// @return state The batch state
    function getBatchState(uint256 batchId) external view returns (BatchState state);
}
