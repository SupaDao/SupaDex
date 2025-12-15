import { ethers, Wallet } from 'ethers';
import { logger } from './logger';
import { config } from './config';
import { db } from './db';
import { OrderAggregator } from './aggregator';
import { SettlementService } from './settlement';
import { BatchMonitor, BatchState } from './monitor';
import { metrics } from './metrics';

/**
 * Main Relayer Service
 */
class RelayerService {
  private provider!: ethers.JsonRpcProvider;
  private wallet!: Wallet;
  private aggregator!: OrderAggregator;
  private settlement!: SettlementService;
  private monitor!: BatchMonitor;
  private isRunning: boolean = false;
  private settlementInterval?: NodeJS.Timeout;
  
  /**
   * Initialize the relayer service
   */
  async initialize(): Promise<void> {
    logger.info('Initializing relayer service');
    
    // Setup provider
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    
    // Setup wallet
    this.wallet = new Wallet(config.relayerPrivateKey, this.provider);
    logger.info({ address: this.wallet.address }, 'Relayer wallet initialized');
    
    // Verify network
    const network = await this.provider.getNetwork();
    logger.info({
      chainId: Number(network.chainId),
      expectedChainId: config.chainId,
    }, 'Connected to network');
    
    if (Number(network.chainId) !== config.chainId) {
      throw new Error(`Chain ID mismatch: expected ${config.chainId}, got ${network.chainId}`);
    }
    
    // Get batch auction address from factory
    const auctionAddress = await this.getBatchAuctionAddress();
    logger.info({ auctionAddress }, 'Batch auction address loaded');
    
    // Initialize components
    this.aggregator = new OrderAggregator(this.provider, auctionAddress);
    this.settlement = new SettlementService(this.provider, this.wallet, auctionAddress, this.aggregator);
    this.monitor = new BatchMonitor(this.provider, auctionAddress);
    
    logger.info('Relayer service initialized');
  }
  
  /**
   * Start the relayer service
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      logger.warn('Relayer already running');
      return;
    }
    
    this.isRunning = true;
    logger.info('Starting relayer service');
    
    // Start metrics server
    await metrics.start();
    
    // Start order aggregator
    await this.aggregator.start();
    
    // Start batch monitor
    await this.monitor.start();
    
    // Start settlement loop
    this.startSettlementLoop();
    
    logger.info('Relayer service started successfully');
  }
  
  /**
   * Stop the relayer service
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    
    logger.info('Stopping relayer service');
    this.isRunning = false;
    
    // Stop settlement loop
    if (this.settlementInterval) {
      clearInterval(this.settlementInterval);
      this.settlementInterval = undefined;
    }
    
    // Stop components
    await this.aggregator.stop();
    await this.monitor.stop();
    
    // Close database
    db.close();
    
    logger.info('Relayer service stopped');
  }
  
  /**
   * Start the settlement loop
   */
  private startSettlementLoop(): void {
    // Run settlement check every poll interval
    this.settlementInterval = setInterval(
      () => this.checkAndSettleBatches(),
      config.pollIntervalMs
    );
    
    logger.info({ pollIntervalMs: config.pollIntervalMs }, 'Settlement loop started');
  }
  
  /**
   * Check for batches ready for settlement and settle them
   */
  private async checkAndSettleBatches(): Promise<void> {
    try {
      // Get unsettled batches from database
      const unsettledBatches = db.getUnsettledBatches();
      
      for (const batch of unsettledBatches) {
        // Check if batch is ready for settlement
        const isReady = await this.monitor.isReadyForSettlement(batch.batchId);
        
        if (isReady) {
          logger.info({ batchId: batch.batchId }, 'Attempting settlement');
          
          // Attempt settlement
          const txHash = await this.settlement.settleBatch(batch.batchId);
          
          if (txHash) {
            logger.info({ batchId: batch.batchId, txHash }, 'Batch settled successfully');
          } else {
            logger.warn({ batchId: batch.batchId }, 'Settlement failed or skipped');
          }
        }
      }
      
    } catch (error) {
      logger.error({ error }, 'Error in settlement loop');
    }
  }
  
  /**
   * Get batch auction address from factory
   */
  private async getBatchAuctionAddress(): Promise<string> {
    // If configured directly, use it
    if (config.batchAuctionAddress) {
      return config.batchAuctionAddress;
    }
    
    // Otherwise, get from factory
    // For simplicity, we'll require it to be configured
    // In production, you'd query the factory for auction addresses
    throw new Error('BATCH_AUCTION_ADDRESS not configured');
  }
  
  /**
   * Perform health check
   */
  async healthCheck(): Promise<boolean> {
    try {
      // Check RPC connection
      const blockNumber = await this.provider.getBlockNumber();
      logger.debug({ blockNumber }, 'Health check: RPC connection OK');
      
      // Check wallet balance
      const balance = await this.provider.getBalance(this.wallet.address);
      logger.debug({ balance: ethers.formatEther(balance) }, 'Health check: Wallet balance OK');
      
      if (balance === 0n) {
        logger.warn('Wallet balance is zero');
        return false;
      }
      
      // Check monitor health
      const monitorHealthy = await this.monitor.healthCheck();
      if (!monitorHealthy) {
        logger.warn('Monitor health check failed');
        return false;
      }
      
      return true;
    } catch (error) {
      logger.error({ error }, 'Health check failed');
      return false;
    }
  }
}

/**
 * Main entry point
 */
async function main() {
  logger.info('='.repeat(50));
  logger.info('DEX Relayer Service');
  logger.info('='.repeat(50));
  logger.info({ config: {
    network: config.network,
    chainId: config.chainId,
    relayerAddress: config.relayerAddress,
    metricsPort: config.metricsPort,
  }}, 'Configuration loaded');
  
  const relayer = new RelayerService();
  
  try {
    // Initialize
    await relayer.initialize();
    
    // Start
    await relayer.start();
    
    // Graceful shutdown handling
    const shutdown = async (signal: string) => {
      logger.info({ signal }, 'Received shutdown signal');
      await relayer.stop();
      process.exit(0);
    };
    
    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));
    
    // Periodic health checks
    setInterval(async () => {
      const healthy = await relayer.healthCheck();
      if (!healthy) {
        logger.error('Health check failed - service may be unhealthy');
      }
    }, 60000); // Every minute
    
    logger.info('Relayer service is running. Press Ctrl+C to stop.');
    
  } catch (error) {
    logger.fatal({ error }, 'Fatal error starting relayer');
    process.exit(1);
  }
}

// Run if this is the main module
if (require.main === module) {
  main().catch(error => {
    logger.fatal({ error }, 'Unhandled error');
    process.exit(1);
  });
}

export { RelayerService };
