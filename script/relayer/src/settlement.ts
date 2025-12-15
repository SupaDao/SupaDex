import { ethers, Contract, Wallet } from 'ethers';
import { logger } from './logger';
import { config } from './config';
import { db, Order } from './db';
import { OrderAggregator } from './aggregator';
import { buildMerkleTree, generateAllProofs } from './merkle';
import { retryWithBackoff } from './retry';

// Minimal ABI for BatchAuction settlement
const BATCH_AUCTION_ABI = [
  'function settleBatchWithProof(uint256 batchId, tuple(uint256 clearingPrice, uint256 totalVolume, tuple(uint64 nonce, uint64 expiry, uint128 amount, uint128 limitPrice, uint8 side)[] buyOrders, tuple(uint64 nonce, uint64 expiry, uint128 amount, uint128 limitPrice, uint8 side)[] sellOrders, bytes32[][] buyProofs, bytes32[][] sellProofs) settlement) external',
  'function getBatchState(uint256 batchId) external view returns (uint8)',
  'function getCurrentBatchId() external view returns (uint256)',
];

export interface SettlementData {
  batchId: number;
  clearingPrice: bigint;
  totalVolume: bigint;
  buyOrders: Order[];
  sellOrders: Order[];
  buyProofs: string[][];
  sellProofs: string[][];
}

export class SettlementService {
  private provider: ethers.JsonRpcProvider;
  private wallet: Wallet;
  private auction: Contract;
  private aggregator: OrderAggregator;
  
  constructor(
    provider: ethers.JsonRpcProvider,
    wallet: Wallet,
    auctionAddress: string,
    aggregator: OrderAggregator
  ) {
    this.provider = provider;
    this.wallet = wallet;
    this.auction = new Contract(auctionAddress, BATCH_AUCTION_ABI, wallet);
    this.aggregator = aggregator;
  }
  
  /**
   * Attempt to settle a batch
   */
  async settleBatch(batchId: number): Promise<string | null> {
    try {
      logger.info({ batchId }, 'Starting batch settlement');
      
      // Check if batch is ready for settlement
      const batchState = await this.auction.getBatchState(batchId);
      if (batchState !== 1) { // 1 = Revealing state
        logger.info({ batchId, batchState }, 'Batch not ready for settlement');
        return null;
      }
      
      // Check if already settled
      const batch = db.getBatch(batchId);
      if (batch?.settled) {
        logger.info({ batchId }, 'Batch already settled');
        return null;
      }
      
      // Fetch and validate orders
      const orders = await this.aggregator.getRevealedOrders(batchId);
      const validOrders = this.aggregator.validateOrders(orders);
      
      if (validOrders.length === 0) {
        logger.warn({ batchId }, 'No valid orders to settle');
        return null;
      }
      
      // Separate and sort orders
      const { buyOrders, sellOrders } = this.aggregator.separateOrders(validOrders);
      
      if (buyOrders.length === 0 || sellOrders.length === 0) {
        logger.warn({ batchId, buyCount: buyOrders.length, sellCount: sellOrders.length }, 
          'Need both buy and sell orders');
        return null;
      }
      
      // Calculate clearing price
      const clearingPrice = this.aggregator.calculateClearingPrice(buyOrders, sellOrders);
      
      if (clearingPrice === 0n) {
        logger.warn({ batchId }, 'No clearing price found');
        return null;
      }
      
      // Build merkle tree and generate proofs
      const { buyProofs, sellProofs, ordersRoot } = this.buildProofs(buyOrders, sellOrders);
      
      // Calculate total volume
      const totalVolume = this.calculateTotalVolume(buyOrders, sellOrders, clearingPrice);
      
      // Prepare settlement data
      const settlementData: SettlementData = {
        batchId,
        clearingPrice,
        totalVolume,
        buyOrders,
        sellOrders,
        buyProofs,
        sellProofs,
      };
      
      logger.info({
        batchId,
        clearingPrice: clearingPrice.toString(),
        totalVolume: totalVolume.toString(),
        buyOrderCount: buyOrders.length,
        sellOrderCount: sellOrders.length,
      }, 'Prepared settlement data');
      
      // Submit settlement transaction
      const txHash = await this.submitSettlement(settlementData);
      
      if (txHash) {
        // Mark batch as settled in database
        db.markBatchSettled(batchId, txHash, clearingPrice.toString(), ordersRoot);
        
        // Mark orders as executed
        [...buyOrders, ...sellOrders].forEach(order => {
          db.markOrderExecuted(order.orderHash);
        });
      }
      
      return txHash;
      
    } catch (error) {
      logger.error({ batchId, error }, 'Error settling batch');
      return null;
    }
  }
  
  /**
   * Build merkle tree and generate proofs for orders
   */
  private buildProofs(buyOrders: Order[], sellOrders: Order[]): {
    buyProofs: string[][];
    sellProofs: string[][];
    ordersRoot: string;
  } {
    // Create leaf hashes for all orders
    const buyLeaves = buyOrders.map(o => o.orderHash);
    const sellLeaves = sellOrders.map(o => o.orderHash);
    const allLeaves = [...buyLeaves, ...sellLeaves];
    
    // Build merkle tree
    const tree = buildMerkleTree(allLeaves);
    
    // Generate proofs for buy orders
    const buyProofs = buyLeaves.map(leaf => {
      const proof = generateAllProofs(tree).find(p => p.leaf === leaf);
      return proof?.proof || [];
    });
    
    // Generate proofs for sell orders
    const sellProofs = sellLeaves.map(leaf => {
      const proof = generateAllProofs(tree).find(p => p.leaf === leaf);
      return proof?.proof || [];
    });
    
    return {
      buyProofs,
      sellProofs,
      ordersRoot: tree.root,
    };
  }
  
  /**
   * Calculate total volume that will be executed
   */
  private calculateTotalVolume(
    buyOrders: Order[],
    sellOrders: Order[],
    clearingPrice: bigint
  ): bigint {
    // Sum buy volume at or above clearing price
    const buyVolume = buyOrders
      .filter(o => BigInt(o.limitPrice) >= clearingPrice)
      .reduce((sum, o) => sum + BigInt(o.amount), 0n);
    
    // Sum sell volume at or below clearing price
    const sellVolume = sellOrders
      .filter(o => BigInt(o.limitPrice) <= clearingPrice)
      .reduce((sum, o) => sum + BigInt(o.amount), 0n);
    
    // Total volume is the minimum of buy and sell
    return buyVolume < sellVolume ? buyVolume : sellVolume;
  }
  
  /**
   * Submit settlement transaction to blockchain
   */
  private async submitSettlement(data: SettlementData): Promise<string | null> {
    return retryWithBackoff(async () => {
      // Estimate gas
      const gasEstimate = await this.auction.settleBatchWithProof.estimateGas(
        data.batchId,
        this.formatSettlementData(data)
      );
      
      logger.info({ batchId: data.batchId, gasEstimate: gasEstimate.toString() }, 
        'Gas estimated');
      
      // Get gas price
      const feeData = await this.provider.getFeeData();
      const maxFeePerGas = feeData.maxFeePerGas || ethers.parseUnits(config.maxGasPriceGwei.toString(), 'gwei');
      const maxPriorityFeePerGas = feeData.maxPriorityFeePerGas || ethers.parseUnits(config.maxPriorityFeeGwei.toString(), 'gwei');
      
      // Check gas price limit
      if (maxFeePerGas > ethers.parseUnits(config.maxGasPriceGwei.toString(), 'gwei')) {
        throw new Error(`Gas price too high: ${ethers.formatUnits(maxFeePerGas, 'gwei')} gwei`);
      }
      
      // Submit transaction
      const tx = await this.auction.settleBatchWithProof(
        data.batchId,
        this.formatSettlementData(data),
        {
          gasLimit: gasEstimate * 120n / 100n, // 20% buffer
          maxFeePerGas,
          maxPriorityFeePerGas,
        }
      );
      
      logger.info({
        batchId: data.batchId,
        txHash: tx.hash,
        gasLimit: tx.gasLimit.toString(),
        maxFeePerGas: ethers.formatUnits(maxFeePerGas, 'gwei'),
      }, 'Settlement transaction submitted');
      
      // Record settlement in database
      db.insertSettlement({
        batchId: data.batchId,
        txHash: tx.hash,
        status: 'pending',
        createdAt: Date.now(),
      });
      
      // Wait for confirmation
      const receipt = await tx.wait();
      
      if (receipt.status === 1) {
        logger.info({
          batchId: data.batchId,
          txHash: tx.hash,
          gasUsed: receipt.gasUsed.toString(),
          blockNumber: receipt.blockNumber,
        }, 'Settlement transaction confirmed');
        
        db.updateSettlementStatus(tx.hash, 'confirmed', Number(receipt.gasUsed));
        return tx.hash;
      } else {
        logger.error({ batchId: data.batchId, txHash: tx.hash }, 'Settlement transaction failed');
        db.updateSettlementStatus(tx.hash, 'failed', undefined, 'Transaction reverted');
        return null;
      }
    }, config.maxRetries);
  }
  
  /**
   * Format settlement data for contract call
   */
  private formatSettlementData(data: SettlementData): any {
    return {
      clearingPrice: data.clearingPrice,
      totalVolume: data.totalVolume,
      buyOrders: data.buyOrders.map(o => ({
        nonce: o.nonce,
        expiry: o.expiry,
        amount: BigInt(o.amount),
        limitPrice: BigInt(o.limitPrice),
        side: o.side,
      })),
      sellOrders: data.sellOrders.map(o => ({
        nonce: o.nonce,
        expiry: o.expiry,
        amount: BigInt(o.amount),
        limitPrice: BigInt(o.limitPrice),
        side: o.side,
      })),
      buyProofs: data.buyProofs,
      sellProofs: data.sellProofs,
    };
  }
}
