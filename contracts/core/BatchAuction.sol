// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IBatchAuction} from "../interfaces/IBatchAuction.sol";
import {CompactEncoding} from "../libraries/CompactEncoding.sol";
import {MerkleProof} from "../libraries/MerkleProof.sol";

/// @title BatchAuction
/// @notice Batch auction with uniform price clearing and merkle proof settlement
/// @dev Implements commit-reveal scheme with off-chain order matching and on-chain settlement verification.
///      Uses merkle proofs to verify order inclusion and clearing price algorithm for fair price discovery.
contract BatchAuction is IBatchAuction, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Role for authorized relayers who can settle batches
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    
    /// @notice Role for pausing the contract in emergencies
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice The base token of the trading pair
    address public TOKEN0;
    
    /// @notice The quote token of the trading pair
    address public TOKEN1;
    
    /// @notice Current active batch ID
    uint256 public currentBatchId;
    
    /// @notice Duration of each batch in blocks
    uint256 public batchDuration;
    
    /// @notice Block number when the last batch started
    uint256 public lastBatchBlock;
    
    /// @notice Minimum order size to prevent spam
    uint128 public minOrderSize;
    
    /// @notice Maximum price deviation allowed (basis points)
    uint16 public maxPriceDeviationBps;
    
    /// @notice Fee charged on each trade (basis points)
    uint24 public feeBps;
    
    /// @notice Accumulated protocol fees for TOKEN0
    uint256 public accumulatedFees0;
    
    /// @notice Accumulated protocol fees for TOKEN1
    uint256 public accumulatedFees1;
    
    /// @notice Mapping from batch ID to batch data
    mapping(uint256 => Batch) public batches;
    
    /// @notice Mapping from commitment hash to existence
    mapping(bytes32 => bool) public commitments;
    
    /// @notice Mapping from commitment hash to revealed status
    mapping(bytes32 => bool) public revealed;
    
    /// @notice Mapping from order hash to execution status
    mapping(bytes32 => OrderExecution) public executions;
    
    /// @notice Mapping from user to their locked balances
    mapping(address => UserBalance) public userBalances;

    /// @notice Mapping from order hash to trader address
    mapping(bytes32 => address) public orderOwners;
    
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Batch data structure
    struct Batch {
        uint256 startBlock;
        uint256 endBlock;
        bytes32 ordersRoot;
        uint256 clearingPrice;
        uint256 totalVolume;
        uint256 buyVolume;
        uint256 sellVolume;
        bool settled;
    }
    
    /// @notice Order execution tracking
    struct OrderExecution {
        bool executed;
        uint128 filledAmount;
        uint128 receivedAmount;
    }
    
    /// @notice User balance tracking
    struct UserBalance {
        uint256 locked0;
        uint256 locked1;
    }
    
    /// @notice Settlement data structure
    struct Settlement {
        uint256 clearingPrice;
        uint256 totalVolume;
        Order[] buyOrders;
        Order[] sellOrders;
        bytes32[][] buyProofs;
        bytes32[][] sellProofs;
    }
    
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Emitted when a new batch starts
    event BatchStarted(uint256 indexed batchId, uint256 startBlock);
    
    /// @notice Emitted when an order is executed
    event OrderExecuted(
        bytes32 indexed orderHash,
        address indexed trader,
        uint128 filledAmount,
        uint128 receivedAmount,
        uint256 clearingPrice
    );
    
    /// @notice Emitted when fees are collected
    event FeesCollected(address indexed recipient, uint256 amount0, uint256 amount1);
    
    /// @notice Emitted when parameters are updated
    event ParametersUpdated(uint256 batchDuration, uint128 minOrderSize, uint16 maxPriceDeviationBps, uint24 feeBps);
    
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error BatchNotOpen();
    error BatchNotRevealing();
    error AlreadySettled();
    error InvalidCommitment();
    error AlreadyRevealed();
    error OrderExpired();
    error OrderTooSmall();
    error InvalidProof();
    error PriceDeviationTooHigh();
    error InsufficientBalance();
    error OrderAlreadyExecuted();
    
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Initializes the batch auction
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the batch auction
    /// @param _token0 Address of the base token
    /// @param _token1 Address of the quote token
    /// @param _batchDuration Duration of each batch in blocks
    /// @param _minOrderSize Minimum order size
    /// @param _maxPriceDeviationBps Maximum price deviation in basis points
    /// @param _feeBps Fee in basis points
    function initialize(
        address _token0,
        address _token1,
        uint256 _batchDuration,
        uint128 _minOrderSize,
        uint16 _maxPriceDeviationBps,
        uint24 _feeBps
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_token0 != address(0) && _token1 != address(0), "Invalid tokens");
        require(_token0 != _token1, "Same tokens");
        require(_batchDuration > 0, "Invalid duration");
        require(_feeBps <= 10000, "Fee too high");
        
        TOKEN0 = _token0;
        TOKEN1 = _token1;
        batchDuration = _batchDuration;
        minOrderSize = _minOrderSize;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        feeBps = _feeBps;
        lastBatchBlock = block.number;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELAYER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        
        emit BatchStarted(0, block.number);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
    
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
    
    /*//////////////////////////////////////////////////////////////
                        COMMITMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Commits to an order without revealing details
    /// @param commitment Hash of the order + salt
    /// @dev Users must lock tokens when committing
    function commitOrder(bytes32 commitment) external override nonReentrant whenNotPaused {
        if (getBatchState(currentBatchId) != IBatchAuction.BatchState.Open) revert BatchNotOpen();
        
        commitments[commitment] = true;
        emit CommitmentSubmitted(msg.sender, commitment, currentBatchId);
    }
    
    /// @notice Commits and locks tokens for an order
    /// @param commitment Hash of the order + salt
    /// @param amount Amount to lock
    /// @param isBuyOrder Whether this is a buy order (locks TOKEN1) or sell order (locks TOKEN0)
    /// @dev Locks tokens to ensure order can be executed
    function commitOrderWithLock(
        bytes32 commitment,
        uint256 amount,
        bool isBuyOrder
    ) external nonReentrant whenNotPaused {
        if (getBatchState(currentBatchId) != IBatchAuction.BatchState.Open) revert BatchNotOpen();
        
        commitments[commitment] = true;
        
        // Lock tokens
        if (isBuyOrder) {
            IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), amount);
            userBalances[msg.sender].locked1 += amount;
        } else {
            IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), amount);
            userBalances[msg.sender].locked0 += amount;
        }
        
        emit CommitmentSubmitted(msg.sender, commitment, currentBatchId);
    }
    
    /// @notice Reveals an order during the revealing phase
    /// @param order The order details
    /// @param salt Random salt used in commitment
    /// @dev Verifies the commitment matches the revealed order
    function revealOrder(Order calldata order, bytes32 salt) external override whenNotPaused {
        if (getBatchState(currentBatchId) != IBatchAuction.BatchState.Revealing) revert BatchNotRevealing();
        
        // Verify commitment
        bytes32 commitment = _hashOrder(order, salt);
        if (!commitments[commitment]) revert InvalidCommitment();
        if (revealed[commitment]) revert AlreadyRevealed();
        if (order.expiry < block.timestamp) revert OrderExpired();
        if (order.amount < minOrderSize) revert OrderTooSmall();
        
        revealed[commitment] = true;
        bytes32 orderHash = keccak256(abi.encode(order));
        orderOwners[orderHash] = msg.sender;
        
        emit OrderRevealed(msg.sender, commitment, currentBatchId);
    }
    
    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Settles a batch with merkle proof verification
    /// @param batchId The batch ID to settle
    /// @param settlement The settlement data including orders and proofs
    /// @dev Only callable by relayers. Verifies all proofs and executes orders at clearing price.
    function settleBatchWithProof(
        uint256 batchId,
        Settlement calldata settlement
    ) external onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused {
        Batch storage batch = batches[batchId];
        if (batch.settled) revert AlreadySettled();
        
        // Verify we're past the revealing phase
        require(getBatchState(batchId) == IBatchAuction.BatchState.Revealing, "Not ready for settlement");
        
        // Calculate and verify clearing price
        uint256 clearingPrice = _calculateClearingPrice(
            settlement.buyOrders,
            settlement.sellOrders
        );
        
        // Verify price is within acceptable deviation
        if (settlement.clearingPrice != clearingPrice) {
            uint256 deviation = _calculateDeviation(settlement.clearingPrice, clearingPrice);
            if (deviation > maxPriceDeviationBps) revert PriceDeviationTooHigh();
        }
        
        // Build merkle tree and verify proofs
        bytes32 ordersRoot = _buildAndVerifyMerkleTree(
            settlement.buyOrders,
            settlement.sellOrders,
            settlement.buyProofs,
            settlement.sellProofs
        );
        
        // Execute all orders at clearing price
        (uint256 totalVolume, uint256 buyVolume, uint256 sellVolume) = _executeOrders(
            settlement.buyOrders,
            settlement.sellOrders,
            settlement.clearingPrice
        );
        
        // Update batch state
        batch.ordersRoot = ordersRoot;
        batch.clearingPrice = settlement.clearingPrice;
        batch.totalVolume = totalVolume;
        batch.buyVolume = buyVolume;
        batch.sellVolume = sellVolume;
        batch.settled = true;
        batch.endBlock = block.number;
        
        emit BatchSettled(batchId, settlement.clearingPrice, totalVolume);
        
        // Start next batch if this was the current one
        if (batchId == currentBatchId) {
            currentBatchId++;
            lastBatchBlock = block.number;
            emit BatchStarted(currentBatchId, block.number);
        }
    }
    
    /// @notice Simplified settlement for testing (without proofs)
    /// @param batchId The batch ID
    /// @param clearingPrice The clearing price
    /// @param ordersRoot The merkle root of orders
    /// @dev Legacy function for backward compatibility
    function settleBatch(
        uint256 batchId,
        uint256 clearingPrice,
        bytes32 ordersRoot
    ) external override onlyRole(RELAYER_ROLE) {
        Batch storage batch = batches[batchId];
        if (batch.settled) revert AlreadySettled();
        
        batch.clearingPrice = clearingPrice;
        batch.ordersRoot = ordersRoot;
        batch.settled = true;
        batch.endBlock = block.number;
        
        emit BatchSettled(batchId, clearingPrice, 0);
        
        if (batchId == currentBatchId) {
            currentBatchId++;
            lastBatchBlock = block.number;
            emit BatchStarted(currentBatchId, block.number);
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Calculates the clearing price using uniform price auction algorithm
    /// @param buyOrders Array of buy orders
    /// @param sellOrders Array of sell orders
    /// @return clearingPrice The calculated clearing price
    /// @dev Finds the price where supply meets demand
    function _calculateClearingPrice(
        Order[] calldata buyOrders,
        Order[] calldata sellOrders
    ) internal pure returns (uint256 clearingPrice) {
        if (buyOrders.length == 0 || sellOrders.length == 0) {
            return 0;
        }
        
        // Build demand curve (buy orders sorted by price descending)
        uint256[] memory buyPrices = new uint256[](buyOrders.length);
        uint256[] memory buyVolumes = new uint256[](buyOrders.length);
        for (uint256 i = 0; i < buyOrders.length; i++) {
            buyPrices[i] = buyOrders[i].limitPrice;
            buyVolumes[i] = buyOrders[i].amount;
        }
        
        // Build supply curve (sell orders sorted by price ascending)
        uint256[] memory sellPrices = new uint256[](sellOrders.length);
        uint256[] memory sellVolumes = new uint256[](sellOrders.length);
        for (uint256 i = 0; i < sellOrders.length; i++) {
            sellPrices[i] = sellOrders[i].limitPrice;
            sellVolumes[i] = sellOrders[i].amount;
        }
        
        // Find intersection (clearing price)
        uint256 cumulativeBuyVolume = 0;
        uint256 cumulativeSellVolume = 0;
        uint256 maxPrice = 0;
        uint256 minPrice = type(uint256).max;
        
        // Find price range where orders can match
        for (uint256 i = 0; i < buyOrders.length; i++) {
            if (buyPrices[i] > maxPrice) maxPrice = buyPrices[i];
        }
        for (uint256 i = 0; i < sellOrders.length; i++) {
            if (sellPrices[i] < minPrice) minPrice = sellPrices[i];
        }
        
        // Clearing price is the midpoint of the overlap
        if (maxPrice >= minPrice) {
            clearingPrice = (maxPrice + minPrice) / 2;
        }
        
        return clearingPrice;
    }
    
    /// @notice Builds merkle tree and verifies all proofs
    /// @param buyOrders Buy orders
    /// @param sellOrders Sell orders
    /// @param buyProofs Merkle proofs for buy orders
    /// @param sellProofs Merkle proofs for sell orders
    /// @return root The computed merkle root
    function _buildAndVerifyMerkleTree(
        Order[] calldata buyOrders,
        Order[] calldata sellOrders,
        bytes32[][] calldata buyProofs,
        bytes32[][] calldata sellProofs
    ) internal pure returns (bytes32 root) {
        // Create leaf hashes
        bytes32[] memory leaves = new bytes32[](buyOrders.length + sellOrders.length);
        
        for (uint256 i = 0; i < buyOrders.length; i++) {
            leaves[i] = keccak256(abi.encode(buyOrders[i]));
        }
        
        for (uint256 i = 0; i < sellOrders.length; i++) {
            leaves[buyOrders.length + i] = keccak256(abi.encode(sellOrders[i]));
        }
        
        // Clone leaves for root computation because computeRoot mutates the array
        bytes32[] memory leavesForRoot = new bytes32[](leaves.length);
        for(uint i=0; i<leaves.length; i++) {
            leavesForRoot[i] = leaves[i];
        }

        // Compute root
        root = MerkleProof.computeRoot(leavesForRoot);
        
        // Verify all proofs
        for (uint256 i = 0; i < buyOrders.length; i++) {
            if (!MerkleProof.verify(buyProofs[i], root, leaves[i])) {
                revert InvalidProof();
            }
        }
        
        for (uint256 i = 0; i < sellOrders.length; i++) {
            if (!MerkleProof.verify(sellProofs[i], root, leaves[buyOrders.length + i])) {
                revert InvalidProof();
            }
        }
        
        return root;
    }
    
    /// @notice Executes all orders at the clearing price
    /// @param buyOrders Buy orders to execute
    /// @param sellOrders Sell orders to execute
    /// @param clearingPrice The clearing price
    /// @return totalVolume Total volume executed
    /// @return buyVolume Total buy volume
    /// @return sellVolume Total sell volume
    function _executeOrders(
        Order[] calldata buyOrders,
        Order[] calldata sellOrders,
        uint256 clearingPrice
    ) internal returns (uint256 totalVolume, uint256 buyVolume, uint256 sellVolume) {
        // Execute buy orders
        for (uint256 i = 0; i < buyOrders.length; i++) {
            if (buyOrders[i].limitPrice >= clearingPrice) {
                uint128 filled = _executeBuyOrder(buyOrders[i], clearingPrice);
                buyVolume += filled;
                totalVolume += filled;
            }
        }
        
        // Execute sell orders
        for (uint256 i = 0; i < sellOrders.length; i++) {
            if (sellOrders[i].limitPrice <= clearingPrice) {
                uint128 filled = _executeSellOrder(sellOrders[i], clearingPrice);
                sellVolume += filled;
            }
        }
        
        // Ensure buy and sell volumes match (or handle partial fills)
        if (buyVolume > sellVolume) {
            totalVolume = sellVolume;
        } else {
            totalVolume = buyVolume;
        }
        
        return (totalVolume, buyVolume, sellVolume);
    }
    
    /// @notice Executes a single buy order
    /// @param order The buy order
    /// @param clearingPrice The clearing price
    /// @return filled Amount filled
    function _executeBuyOrder(Order calldata order, uint256 clearingPrice) internal returns (uint128 filled) {
        bytes32 orderHash = keccak256(abi.encode(order));
        
        if (executions[orderHash].executed) revert OrderAlreadyExecuted();
        
        // Calculate amounts
        filled = order.amount;
        uint256 quoteAmount = (uint256(filled) * clearingPrice) / 1e18;
        uint256 feeAmount = (quoteAmount * feeBps) / 10000;
        uint128 received = uint128(quoteAmount - feeAmount);
        
        // Update execution status
        executions[orderHash] = OrderExecution({
            executed: true,
            filledAmount: filled,
            receivedAmount: received
        });
        
        // Transfer tokens (buyer receives TOKEN0, pays TOKEN1)
        address trader = _getTraderFromOrder(order);
        
        // Deduct from locked balance or transfer
        if (userBalances[trader].locked1 >= quoteAmount) {
            userBalances[trader].locked1 -= quoteAmount;
        } else {
            IERC20(TOKEN1).safeTransferFrom(trader, address(this), quoteAmount);
        }
        
        // Transfer TOKEN0 to buyer
        IERC20(TOKEN0).safeTransfer(trader, filled);
        
        // Collect fee
        accumulatedFees1 += feeAmount;
        
        emit OrderExecuted(orderHash, trader, filled, received, clearingPrice);
        
        return filled;
    }
    
    /// @notice Executes a single sell order
    /// @param order The sell order
    /// @param clearingPrice The clearing price
    /// @return filled Amount filled
    function _executeSellOrder(Order calldata order, uint256 clearingPrice) internal returns (uint128 filled) {
        bytes32 orderHash = keccak256(abi.encode(order));
        
        if (executions[orderHash].executed) revert OrderAlreadyExecuted();
        
        // Calculate amounts
        filled = order.amount;
        uint256 quoteAmount = (uint256(filled) * clearingPrice) / 1e18;
        uint256 feeAmount = (filled * feeBps) / 10000;
        uint128 received = uint128(quoteAmount);
        
        // Update execution status
        executions[orderHash] = OrderExecution({
            executed: true,
            filledAmount: filled,
            receivedAmount: received
        });
        
        // Transfer tokens (seller receives TOKEN1, pays TOKEN0)
        address trader = _getTraderFromOrder(order);
        
        // Deduct from locked balance or transfer
        if (userBalances[trader].locked0 >= filled) {
            userBalances[trader].locked0 -= filled;
        } else {
            IERC20(TOKEN0).safeTransferFrom(trader, address(this), filled);
        }
        
        // Transfer TOKEN1 to seller
        IERC20(TOKEN1).safeTransfer(trader, quoteAmount);
        
        // Collect fee
        accumulatedFees0 += feeAmount;
        
        emit OrderExecuted(orderHash, trader, filled, received, clearingPrice);
        
        return filled;
    }
    
    /// @notice Hashes an order with salt for commitment
    /// @param order The order
    /// @param salt Random salt
    /// @return hash The commitment hash
    function _hashOrder(Order calldata order, bytes32 salt) internal pure returns (bytes32 hash) {
        CompactEncoding.CompactOrder memory compactOrder = CompactEncoding.CompactOrder({
            nonce: order.nonce,
            expiry: order.expiry,
            amount: order.amount,
            limitPrice: order.limitPrice,
            side: order.side
        });
        return CompactEncoding.hashOrder(compactOrder, salt);
    }
    
    /// @notice Extracts trader address from order (placeholder - needs proper implementation)
    /// @param order The order
    /// @return trader The trader address
    /// @dev In production, this would be part of the order struct or derived from signature
    function _getTraderFromOrder(Order calldata order) internal view returns (address trader) {
        bytes32 orderHash = keccak256(abi.encode(order));
        return orderOwners[orderHash];
    }
    
    /// @notice Calculates price deviation in basis points
    /// @param price1 First price
    /// @param price2 Second price
    /// @return deviation Deviation in basis points
    function _calculateDeviation(uint256 price1, uint256 price2) internal pure returns (uint256 deviation) {
        if (price1 > price2) {
            deviation = ((price1 - price2) * 10000) / price2;
        } else {
            deviation = ((price2 - price1) * 10000) / price1;
        }
        return deviation;
    }
    
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Gets the current batch ID
    /// @return batchId The current batch ID
    function getCurrentBatchId() external view override returns (uint256 batchId) {
        return currentBatchId;
    }
    
    /// @notice Gets the state of a batch
    /// @param batchId The batch ID
    /// @return state The batch state (0=Open, 1=Revealing, 2=Settled)
    function getBatchState(uint256 batchId) public view override returns (IBatchAuction.BatchState state) {
        if (batches[batchId].settled) return IBatchAuction.BatchState.Settled;
        if (block.number > lastBatchBlock + batchDuration) return IBatchAuction.BatchState.Revealing;
        return IBatchAuction.BatchState.Open;
    }
    
    /// @notice Gets batch information
    /// @param batchId The batch ID
    /// @return batch The batch data
    function getBatch(uint256 batchId) external view returns (Batch memory batch) {
        return batches[batchId];
    }
    
    /// @notice Gets order execution status
    /// @param orderHash The order hash
    /// @return execution The execution data
    function getOrderExecution(bytes32 orderHash) external view returns (OrderExecution memory execution) {
        return executions[orderHash];
    }
    
    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Updates auction parameters
    /// @param _batchDuration New batch duration
    /// @param _minOrderSize New minimum order size
    /// @param _maxPriceDeviationBps New max price deviation
    /// @param _feeBps New fee in basis points
    function updateParameters(
        uint256 _batchDuration,
        uint128 _minOrderSize,
        uint16 _maxPriceDeviationBps,
        uint24 _feeBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_batchDuration > 0, "Invalid duration");
        require(_feeBps <= 10000, "Fee too high");
        
        batchDuration = _batchDuration;
        minOrderSize = _minOrderSize;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        feeBps = _feeBps;
        
        emit ParametersUpdated(_batchDuration, _minOrderSize, _maxPriceDeviationBps, _feeBps);
    }
    
    /// @notice Collects accumulated protocol fees
    /// @param recipient Fee recipient address
    function collectFees(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        
        uint256 fees0 = accumulatedFees0;
        uint256 fees1 = accumulatedFees1;
        
        if (fees0 > 0) {
            accumulatedFees0 = 0;
            IERC20(TOKEN0).safeTransfer(recipient, fees0);
        }
        
        if (fees1 > 0) {
            accumulatedFees1 = 0;
            IERC20(TOKEN1).safeTransfer(recipient, fees1);
        }
        
        emit FeesCollected(recipient, fees0, fees1);
    }
    
    /// @notice Pauses the contract
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /// @notice Unpauses the contract
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /// @notice Emergency withdrawal when paused
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param recipient Recipient address
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(PAUSER_ROLE) whenPaused {
        require(recipient != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(recipient, amount);
    }
}
