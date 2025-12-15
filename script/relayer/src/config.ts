import dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';

dotenv.config();

export interface RelayerConfig {
  // Network
  network: string;
  rpcUrl: string;
  backupRpcUrl?: string;
  chainId: number;
  
  // Contracts
  factoryAddress: string;
  batchAuctionAddress?: string;
  
  // Relayer
  relayerPrivateKey: string;
  relayerAddress: string;
  
  // Gas
  maxGasPriceGwei: number;
  maxPriorityFeeGwei: number;
  gasLimit: number;
  
  // Database
  databasePath: string;
  
  // Monitoring
  enableMetrics: boolean;
  metricsPort: number;
  healthCheckPort: number;
  
  // Logging
  logLevel: string;
  logPretty: boolean;
  
  // Retry
  maxRetries: number;
  retryDelayMs: number;
  retryBackoffMultiplier: number;
  
  // Batch
  pollIntervalMs: number;
  settlementDelayBlocks: number;
}

/**
 * Loads configuration from environment variables and deployment files
 */
export function loadConfig(): RelayerConfig {
  const network = process.env.NETWORK || 'localhost';
  
  // Load deployment addresses
  const deploymentPath = path.join(__dirname, '../../../deployments', `${network}.json`);
  let factoryAddress = process.env.FACTORY_ADDRESS;
  let batchAuctionAddress = process.env.BATCH_AUCTION_ADDRESS;
  
  if (fs.existsSync(deploymentPath)) {
    const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf-8'));
    factoryAddress = factoryAddress || deployment.contracts.factory;
    // Batch auction address would be loaded from factory or deployment
  }
  
  if (!factoryAddress) {
    throw new Error('Factory address not configured. Set FACTORY_ADDRESS or deploy contracts first.');
  }
  
  const config: RelayerConfig = {
    // Network
    network,
    rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
    backupRpcUrl: process.env.BACKUP_RPC_URL,
    chainId: parseInt(process.env.CHAIN_ID || '31337'),
    
    // Contracts
    factoryAddress,
    batchAuctionAddress,
    
    // Relayer
    relayerPrivateKey: process.env.RELAYER_PRIVATE_KEY || '',
    relayerAddress: process.env.RELAYER_ADDRESS || '',
    
    // Gas
    maxGasPriceGwei: parseFloat(process.env.MAX_GAS_PRICE_GWEI || '100'),
    maxPriorityFeeGwei: parseFloat(process.env.MAX_PRIORITY_FEE_GWEI || '2'),
    gasLimit: parseInt(process.env.GAS_LIMIT || '500000'),
    
    // Database
    databasePath: process.env.DATABASE_PATH || './relayer.db',
    
    // Monitoring
    enableMetrics: process.env.ENABLE_METRICS === 'true',
    metricsPort: parseInt(process.env.METRICS_PORT || '9090'),
    healthCheckPort: parseInt(process.env.HEALTH_CHECK_PORT || '8080'),
    
    // Logging
    logLevel: process.env.LOG_LEVEL || 'info',
    logPretty: process.env.LOG_PRETTY === 'true',
    
    // Retry
    maxRetries: parseInt(process.env.MAX_RETRIES || '3'),
    retryDelayMs: parseInt(process.env.RETRY_DELAY_MS || '5000'),
    retryBackoffMultiplier: parseFloat(process.env.RETRY_BACKOFF_MULTIPLIER || '2'),
    
    // Batch
    pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS || '12000'),
    settlementDelayBlocks: parseInt(process.env.SETTLEMENT_DELAY_BLOCKS || '2'),
  };
  
  // Validate required fields
  if (!config.relayerPrivateKey) {
    throw new Error('RELAYER_PRIVATE_KEY is required');
  }
  
  return config;
}

export const config = loadConfig();
