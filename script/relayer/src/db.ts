import Database from 'better-sqlite3';
import { config } from './config';
import { logger } from './logger';

export interface Order {
  orderHash: string;
  batchId: number;
  trader: string;
  nonce: number;
  expiry: number;
  amount: string;
  limitPrice: string;
  side: number;
  revealed: boolean;
  executed: boolean;
  createdAt: number;
}

export interface Batch {
  batchId: number;
  startBlock: number;
  endBlock?: number;
  clearingPrice?: string;
  ordersRoot?: string;
  settled: boolean;
  txHash?: string;
  createdAt: number;
  settledAt?: number;
}

export interface Settlement {
  id?: number;
  batchId: number;
  txHash: string;
  status: 'pending' | 'confirmed' | 'failed';
  gasUsed?: number;
  error?: string;
  createdAt: number;
  confirmedAt?: number;
}

export class Database {
  private db: Database.Database;
  
  constructor(dbPath: string = config.databasePath) {
    this.db = new Database(dbPath);
    this.initialize();
    logger.info({ dbPath }, 'Database initialized');
  }
  
  /**
   * Initialize database schema
   */
  private initialize(): void {
    // Create orders table
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS orders (
        orderHash TEXT PRIMARY KEY,
        batchId INTEGER NOT NULL,
        trader TEXT NOT NULL,
        nonce INTEGER NOT NULL,
        expiry INTEGER NOT NULL,
        amount TEXT NOT NULL,
        limitPrice TEXT NOT NULL,
        side INTEGER NOT NULL,
        revealed INTEGER DEFAULT 0,
        executed INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL,
        INDEX idx_batch (batchId),
        INDEX idx_trader (trader),
        INDEX idx_revealed (revealed),
        INDEX idx_executed (executed)
      )
    `);
    
    // Create batches table
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS batches (
        batchId INTEGER PRIMARY KEY,
        startBlock INTEGER NOT NULL,
        endBlock INTEGER,
        clearingPrice TEXT,
        ordersRoot TEXT,
        settled INTEGER DEFAULT 0,
        txHash TEXT,
        createdAt INTEGER NOT NULL,
        settledAt INTEGER,
        INDEX idx_settled (settled)
      )
    `);
    
    // Create settlements table
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS settlements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        batchId INTEGER NOT NULL,
        txHash TEXT NOT NULL,
        status TEXT NOT NULL,
        gasUsed INTEGER,
        error TEXT,
        createdAt INTEGER NOT NULL,
        confirmedAt INTEGER,
        INDEX idx_batch (batchId),
        INDEX idx_status (status)
      )
    `);
  }
  
  /*//////////////////////////////////////////////////////////////
                          ORDER OPERATIONS
  //////////////////////////////////////////////////////////////*/
  
  /**
   * Insert or update an order
   */
  insertOrder(order: Order): void {
    const stmt = this.db.prepare(`
      INSERT OR REPLACE INTO orders 
      (orderHash, batchId, trader, nonce, expiry, amount, limitPrice, side, revealed, executed, createdAt)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    stmt.run(
      order.orderHash,
      order.batchId,
      order.trader,
      order.nonce,
      order.expiry,
      order.amount,
      order.limitPrice,
      order.side,
      order.revealed ? 1 : 0,
      order.executed ? 1 : 0,
      order.createdAt
    );
  }
  
  /**
   * Get orders by batch ID
   */
  getOrdersByBatch(batchId: number, revealedOnly: boolean = true): Order[] {
    const query = revealedOnly
      ? 'SELECT * FROM orders WHERE batchId = ? AND revealed = 1 AND executed = 0'
      : 'SELECT * FROM orders WHERE batchId = ?';
    
    const stmt = this.db.prepare(query);
    const rows = stmt.all(batchId) as any[];
    
    return rows.map(row => ({
      ...row,
      revealed: row.revealed === 1,
      executed: row.executed === 1,
    }));
  }
  
  /**
   * Mark order as executed
   */
  markOrderExecuted(orderHash: string): void {
    const stmt = this.db.prepare('UPDATE orders SET executed = 1 WHERE orderHash = ?');
    stmt.run(orderHash);
  }
  
  /*//////////////////////////////////////////////////////////////
                          BATCH OPERATIONS
  //////////////////////////////////////////////////////////////*/
  
  /**
   * Insert or update a batch
   */
  insertBatch(batch: Batch): void {
    const stmt = this.db.prepare(`
      INSERT OR REPLACE INTO batches
      (batchId, startBlock, endBlock, clearingPrice, ordersRoot, settled, txHash, createdAt, settledAt)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    stmt.run(
      batch.batchId,
      batch.startBlock,
      batch.endBlock,
      batch.clearingPrice,
      batch.ordersRoot,
      batch.settled ? 1 : 0,
      batch.txHash,
      batch.createdAt,
      batch.settledAt
    );
  }
  
  /**
   * Get batch by ID
   */
  getBatch(batchId: number): Batch | null {
    const stmt = this.db.prepare('SELECT * FROM batches WHERE batchId = ?');
    const row = stmt.get(batchId) as any;
    
    if (!row) return null;
    
    return {
      ...row,
      settled: row.settled === 1,
    };
  }
  
  /**
   * Get unsettled batches
   */
  getUnsettledBatches(): Batch[] {
    const stmt = this.db.prepare('SELECT * FROM batches WHERE settled = 0 ORDER BY batchId ASC');
    const rows = stmt.all() as any[];
    
    return rows.map(row => ({
      ...row,
      settled: row.settled === 1,
    }));
  }
  
  /**
   * Mark batch as settled
   */
  markBatchSettled(batchId: number, txHash: string, clearingPrice: string, ordersRoot: string): void {
    const stmt = this.db.prepare(`
      UPDATE batches 
      SET settled = 1, txHash = ?, clearingPrice = ?, ordersRoot = ?, settledAt = ?
      WHERE batchId = ?
    `);
    
    stmt.run(txHash, clearingPrice, ordersRoot, Date.now(), batchId);
  }
  
  /*//////////////////////////////////////////////////////////////
                        SETTLEMENT OPERATIONS
  //////////////////////////////////////////////////////////////*/
  
  /**
   * Insert a settlement record
   */
  insertSettlement(settlement: Settlement): number {
    const stmt = this.db.prepare(`
      INSERT INTO settlements (batchId, txHash, status, gasUsed, error, createdAt, confirmedAt)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `);
    
    const result = stmt.run(
      settlement.batchId,
      settlement.txHash,
      settlement.status,
      settlement.gasUsed,
      settlement.error,
      settlement.createdAt,
      settlement.confirmedAt
    );
    
    return result.lastInsertRowid as number;
  }
  
  /**
   * Update settlement status
   */
  updateSettlementStatus(
    txHash: string,
    status: 'confirmed' | 'failed',
    gasUsed?: number,
    error?: string
  ): void {
    const stmt = this.db.prepare(`
      UPDATE settlements 
      SET status = ?, gasUsed = ?, error = ?, confirmedAt = ?
      WHERE txHash = ?
    `);
    
    stmt.run(status, gasUsed, error, Date.now(), txHash);
  }
  
  /*//////////////////////////////////////////////////////////////
                            CLEANUP
  //////////////////////////////////////////////////////////////*/
  
  /**
   * Delete old settled batches and their orders
   */
  cleanup(olderThanDays: number = 30): void {
    const cutoffTime = Date.now() - (olderThanDays * 24 * 60 * 60 * 1000);
    
    // Delete old orders
    this.db.prepare('DELETE FROM orders WHERE createdAt < ? AND executed = 1').run(cutoffTime);
    
    // Delete old batches
    this.db.prepare('DELETE FROM batches WHERE settledAt < ? AND settled = 1').run(cutoffTime);
    
    // Delete old settlements
    this.db.prepare('DELETE FROM settlements WHERE confirmedAt < ?').run(cutoffTime);
    
    logger.info({ olderThanDays }, 'Database cleanup completed');
  }
  
  /**
   * Close database connection
   */
  close(): void {
    this.db.close();
    logger.info('Database connection closed');
  }
}

// Export singleton instance
export const db = new Database();
