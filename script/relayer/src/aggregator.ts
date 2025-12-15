import { ethers, Contract, EventLog } from 'ethers';
import { logger } from './logger';
import { db, Order } from './db';
import { config } from './config';

// Minimal ABI for BatchAuction events
const BATCH_AUCTION_ABI = [
  'event CommitmentSubmitted(address indexed trader, bytes32 indexed commitment, uint256 indexed batchId)',
  'event OrderRevealed(address indexed trader, bytes32 indexed commitment, uint256 indexed batchId)',
  'event BatchSettled(uint256 indexed batchId, uint256 clearingPrice, uint256 totalVolume)',
  'function getCurrentBatchId() external view returns (uint256)',
  'function getBatchState(uint256 batchId) external view returns (uint8)',
];

export interface RevealedOrder {
  orderHash: string;
  batchId: number;
  trader: string;
  nonce: number;
  expiry: number;
  amount: bigint;
  limitPrice: bigint;
  side: number;
}

export class OrderAggregator {
  private provider: ethers.JsonRpcProvider;
  private auction: Contract;
  private isRunning: boolean = false;
  
  constructor(provider: ethers.JsonRpcProvider, auctionAddress: string) {
    this.provider = provider;
    this.auction = new Contract(auctionAddress, BATCH_AUCTION_ABI, provider);
  }
  
  /**
   * Start listening for order events
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      logger.warn('Aggregator already running');
      return;
    }
    
    this.isRunning = true;
    logger.info('Starting order aggregator');
    
    // Listen for commitment events
    this.auction.on('CommitmentSubmitted', this.handleCommitment.bind(this));
    
    // Listen for reveal events
    this.auction.on('OrderRevealed', this.handleReveal.bind(this));
    
    // Listen for settlement events
    this.auction.on('BatchSettled', this.handleSettlement.bind(this));
    
    logger.info('Order aggregator started');
  }
  
  /**
   * Stop listening for events
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    
    this.isRunning = false;
    this.auction.removeAllListeners();
    logger.info('Order aggregator stopped');
  }
  
  /**
   * Handle commitment event
   */
  private async handleCommitment(
    trader: string,
    commitment: string,
    batchId: bigint,
    event: EventLog
  ): Promise<void> {
    logger.info({
      trader,
      commitment,
      batchId: Number(batchId),
      blockNumber: event.blockNumber,
    }, 'Commitment received');
    
    // Store commitment for tracking
    // In a full implementation, you'd track commitments to ensure they're revealed
  }
  
  /**
   * Handle order reveal event
   */
  private async handleReveal(
    trader: string,
    commitment: string,
    batchId: bigint,
    event: EventLog
  ): Promise<void> {
    logger.info({
      trader,
      commitment,
      batchId: Number(batchId),
      blockNumber: event.blockNumber,
    }, 'Order revealed');
    
    // In a full implementation, you'd parse the order details from the transaction
    // For now, we'll note that this would require decoding the revealOrder transaction
  }
  
  /**
   * Handle batch settlement event
   */
  private async handleSettlement(
    batchId: bigint,
    clearingPrice: bigint,
    totalVolume: bigint,
    event: EventLog
  ): Promise<void> {
    logger.info({
      batchId: Number(batchId),
      clearingPrice: clearingPrice.toString(),
      totalVolume: totalVolume.toString(),
      blockNumber: event.blockNumber,
    }, 'Batch settled');
    
    // Mark batch as settled in database
    db.markBatchSettled(
      Number(batchId),
      event.transactionHash,
      clearingPrice.toString(),
      '' // ordersRoot would come from transaction data
    );
  }
  
  /**
   * Fetch all revealed orders for a batch
   */
  async getRevealedOrders(batchId: number): Promise<Order[]> {
    // First check database
    const dbOrders = db.getOrdersByBatch(batchId, true);
    
    if (dbOrders.length > 0) {
      logger.info({ batchId, count: dbOrders.length }, 'Loaded orders from database');
      return dbOrders;
    }
    
    // If not in database, fetch from events
    logger.info({ batchId }, 'Fetching orders from blockchain events');
    
    const filter = this.auction.filters.OrderRevealed(null, null, batchId);
    const events = await this.auction.queryFilter(filter);
    
    logger.info({ batchId, count: events.length }, 'Found reveal events');
    
    // Parse events and store in database
    // Note: This is simplified - in production you'd decode transaction data
    const orders: Order[] = [];
    
    for (const event of events) {
      if (event instanceof EventLog) {
        // In production, decode the revealOrder transaction to get order details
        // For now, this is a placeholder
        const order: Order = {
          orderHash: event.args![1] as string, // commitment
          batchId,
          trader: event.args![0] as string,
          nonce: 0,
          expiry: 0,
          amount: '0',
          limitPrice: '0',
          side: 0,
          revealed: true,
          executed: false,
          createdAt: Date.now(),
        };
        
        db.insertOrder(order);
        orders.push(order);
      }
    }
    
    return orders;
  }
  
  /**
   * Validate orders before settlement
   */
  validateOrders(orders: Order[]): Order[] {
    const now = Math.floor(Date.now() / 1000);
    
    return orders.filter(order => {
      // Check expiry
      if (order.expiry < now) {
        logger.warn({ orderHash: order.orderHash }, 'Order expired');
        return false;
      }
      
      // Check amount
      if (BigInt(order.amount) === 0n) {
        logger.warn({ orderHash: order.orderHash }, 'Order amount is zero');
        return false;
      }
      
      // Check price
      if (BigInt(order.limitPrice) === 0n) {
        logger.warn({ orderHash: order.orderHash }, 'Order price is zero');
        return false;
      }
      
      return true;
    });
  }
  
  /**
   * Separate orders into buy and sell
   */
  separateOrders(orders: Order[]): { buyOrders: Order[]; sellOrders: Order[] } {
    const buyOrders = orders.filter(o => o.side === 0);
    const sellOrders = orders.filter(o => o.side === 1);
    
    // Sort buy orders by price descending (highest price first)
    buyOrders.sort((a, b) => {
      const priceA = BigInt(a.limitPrice);
      const priceB = BigInt(b.limitPrice);
      return priceB > priceA ? 1 : priceB < priceA ? -1 : 0;
    });
    
    // Sort sell orders by price ascending (lowest price first)
    sellOrders.sort((a, b) => {
      const priceA = BigInt(a.limitPrice);
      const priceB = BigInt(b.limitPrice);
      return priceA > priceB ? 1 : priceA < priceB ? -1 : 0;
    });
    
    return { buyOrders, sellOrders };
  }
  
  /**
   * Calculate clearing price using uniform price auction
   */
  calculateClearingPrice(buyOrders: Order[], sellOrders: Order[]): bigint {
    if (buyOrders.length === 0 || sellOrders.length === 0) {
      return 0n;
    }
    
    // Find the price where supply meets demand
    const maxBuyPrice = BigInt(buyOrders[0].limitPrice);
    const minSellPrice = BigInt(sellOrders[0].limitPrice);
    
    // Clearing price is the midpoint of the overlap
    if (maxBuyPrice >= minSellPrice) {
      return (maxBuyPrice + minSellPrice) / 2n;
    }
    
    return 0n;
  }
}
