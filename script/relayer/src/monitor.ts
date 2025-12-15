import { ethers, Contract } from 'ethers';
import { logger } from './logger';
import { config } from './config';
import { db } from './db';

// Minimal ABI for batch monitoring
const BATCH_AUCTION_ABI = [
  'function getCurrentBatchId() external view returns (uint256)',
  'function getBatchState(uint256 batchId) external view returns (uint8)',
  'event BatchStarted(uint256 indexed batchId, uint256 startBlock)',
];

export enum BatchState {
  Open = 0,
  Revealing = 1,
  Settled = 2,
}

export interface BatchInfo {
  batchId: number;
  state: BatchState;
  startBlock: number;
}

export class BatchMonitor {
  private provider: ethers.JsonRpcProvider;
  private auction: Contract;
  private isRunning: boolean = false;
  private currentBatchId: number = 0;
  private pollInterval?: NodeJS.Timeout;
  
  constructor(provider: ethers.JsonRpcProvider, auctionAddress: string) {
    this.provider = provider;
    this.auction = new Contract(auctionAddress, BATCH_AUCTION_ABI, provider);
  }
  
  /**
   * Start monitoring batches
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      logger.warn('Monitor already running');
      return;
    }
    
    this.isRunning = true;
    logger.info('Starting batch monitor');
    
    // Get current batch ID
    this.currentBatchId = Number(await this.auction.getCurrentBatchId());
    logger.info({ batchId: this.currentBatchId }, 'Current batch ID');
    
    // Listen for new batch events
    this.auction.on('BatchStarted', this.handleBatchStarted.bind(this));
    
    // Start polling for batch state changes
    this.pollInterval = setInterval(
      () => this.checkBatchState(),
      config.pollIntervalMs
    );
    
    logger.info({ pollIntervalMs: config.pollIntervalMs }, 'Batch monitor started');
  }
  
  /**
   * Stop monitoring
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    
    this.isRunning = false;
    
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = undefined;
    }
    
    this.auction.removeAllListeners();
    logger.info('Batch monitor stopped');
  }
  
  /**
   * Handle new batch started event
   */
  private async handleBatchStarted(batchId: bigint, startBlock: bigint): Promise<void> {
    const id = Number(batchId);
    const block = Number(startBlock);
    
    logger.info({ batchId: id, startBlock: block }, 'New batch started');
    
    this.currentBatchId = id;
    
    // Store batch in database
    db.insertBatch({
      batchId: id,
      startBlock: block,
      settled: false,
      createdAt: Date.now(),
    });
  }
  
  /**
   * Check current batch state
   */
  private async checkBatchState(): Promise<void> {
    try {
      const state = Number(await this.auction.getBatchState(this.currentBatchId));
      const currentBlock = await this.provider.getBlockNumber();
      
      logger.debug({
        batchId: this.currentBatchId,
        state: BatchState[state],
        currentBlock,
      }, 'Batch state check');
      
      // Emit state change events
      if (state === BatchState.Revealing) {
        await this.onBatchRevealing(this.currentBatchId, currentBlock);
      } else if (state === BatchState.Settled) {
        await this.onBatchSettled(this.currentBatchId);
      }
      
    } catch (error) {
      logger.error({ error }, 'Error checking batch state');
    }
  }
  
  /**
   * Called when batch enters revealing state
   */
  private async onBatchRevealing(batchId: number, currentBlock: number): Promise<void> {
    const batch = db.getBatch(batchId);
    
    if (!batch) {
      logger.warn({ batchId }, 'Batch not found in database');
      return;
    }
    
    if (batch.settled) {
      return; // Already settled
    }
    
    // Wait for settlement delay blocks
    const batch Info = await this.getBatchInfo(batchId);
    const blocksSinceStart = currentBlock - batchInfo.startBlock;
    
    if (blocksSinceStart >= config.settlementDelayBlocks) {
      logger.info({ batchId, blocksSinceStart }, 'Batch ready for settlement');
      // Settlement will be triggered by the main loop
    }
  }
  
  /**
   * Called when batch is settled
   */
  private async onBatchSettled(batchId: number): Promise<void> {
    const batch = db.getBatch(batchId);
    
    if (batch && !batch.settled) {
      logger.info({ batchId }, 'Batch settled externally');
      // Mark as settled in database
      db.markBatchSettled(batchId, '', '0', '');
    }
  }
  
  /**
   * Get current batch info
   */
  async getCurrentBatch(): Promise<BatchInfo> {
    return this.getBatchInfo(this.currentBatchId);
  }
  
  /**
   * Get batch info by ID
   */
  async getBatchInfo(batchId: number): Promise<BatchInfo> {
    const state = Number(await this.auction.getBatchState(batchId));
    const batch = db.getBatch(batchId);
    
    return {
      batchId,
      state,
      startBlock: batch?.startBlock || 0,
    };
  }
  
  /**
   * Check if batch is ready for settlement
   */
  async isReadyForSettlement(batchId: number): Promise<boolean> {
    const info = await this.getBatchInfo(batchId);
    
    if (info.state !== BatchState.Revealing) {
      return false;
    }
    
    const currentBlock = await this.provider.getBlockNumber();
    const blocksSinceStart = currentBlock - info.startBlock;
    
    return blocksSinceStart >= config.settlementDelayBlocks;
  }
  
  /**
   * Health check
   */
  async healthCheck(): Promise<boolean> {
    try {
      await this.provider.getBlockNumber();
      return true;
    } catch (error) {
      logger.error({ error }, 'Health check failed');
      return false;
    }
  }
}
