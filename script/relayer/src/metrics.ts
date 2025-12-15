import express, { Request, Response } from 'express';
import { logger } from './logger';
import { config } from './config';
import { db } from './db';

export interface Metrics {
  // Settlement metrics
  totalSettlements: number;
  successfulSettlements: number;
  failedSettlements: number;
  pendingSettlements: number;
  
  // Order metrics
  totalOrders: number;
  executedOrders: number;
  
  // Batch metrics
  totalBatches: number;
  settledBatches: number;
  
  // Performance metrics
  averageSettlementTimeMs: number;
  averageGasUsed: number;
  
  // Uptime
  uptimeSeconds: number;
  startTime: number;
}

export class MetricsCollector {
  private app: express.Application;
  private startTime: number;
  
  constructor() {
    this.app = express();
    this.startTime = Date.now();
    this.setupRoutes();
  }
  
  /**
   * Setup HTTP routes
   */
  private setupRoutes(): void {
    // Health check endpoint
    this.app.get('/health', this.handleHealthCheck.bind(this));
    
    // Metrics endpoint (Prometheus format)
    this.app.get('/metrics', this.handleMetrics.bind(this));
    
    // JSON metrics endpoint
    this.app.get('/metrics/json', this.handleMetricsJson.bind(this));
  }
  
  /**
   * Start metrics server
   */
  async start(): Promise<void> {
    if (!config.enableMetrics) {
      logger.info('Metrics collection disabled');
      return;
    }
    
    this.app.listen(config.metricsPort, () => {
      logger.info({ port: config.metricsPort }, 'Metrics server started');
    });
  }
  
  /**
   * Health check handler
   */
  private async handleHealthCheck(req: Request, res: Response): Promise<void> {
    const health = {
      status: 'healthy',
      timestamp: Date.now(),
      uptime: Date.now() - this.startTime,
      version: '1.0.0',
    };
    
    res.json(health);
  }
  
  /**
   * Metrics handler (Prometheus format)
   */
  private async handleMetrics(req: Request, res: Response): Promise<void> {
    const metrics = await this.collectMetrics();
    
    const prometheusMetrics = `
# HELP relayer_settlements_total Total number of settlement attempts
# TYPE relayer_settlements_total counter
relayer_settlements_total ${metrics.totalSettlements}

# HELP relayer_settlements_successful Number of successful settlements
# TYPE relayer_settlements_successful counter
relayer_settlements_successful ${metrics.successfulSettlements}

# HELP relayer_settlements_failed Number of failed settlements
# TYPE relayer_settlements_failed counter
relayer_settlements_failed ${metrics.failedSettlements}

# HELP relayer_settlements_pending Number of pending settlements
# TYPE relayer_settlements_pending gauge
relayer_settlements_pending ${metrics.pendingSettlements}

# HELP relayer_orders_total Total number of orders processed
# TYPE relayer_orders_total counter
relayer_orders_total ${metrics.totalOrders}

# HELP relayer_orders_executed Number of executed orders
# TYPE relayer_orders_executed counter
relayer_orders_executed ${metrics.executedOrders}

# HELP relayer_batches_total Total number of batches
# TYPE relayer_batches_total counter
relayer_batches_total ${metrics.totalBatches}

# HELP relayer_batches_settled Number of settled batches
# TYPE relayer_batches_settled counter
relayer_batches_settled ${metrics.settledBatches}

# HELP relayer_settlement_time_avg Average settlement time in milliseconds
# TYPE relayer_settlement_time_avg gauge
relayer_settlement_time_avg ${metrics.averageSettlementTimeMs}

# HELP relayer_gas_used_avg Average gas used per settlement
# TYPE relayer_gas_used_avg gauge
relayer_gas_used_avg ${metrics.averageGasUsed}

# HELP relayer_uptime_seconds Relayer uptime in seconds
# TYPE relayer_uptime_seconds counter
relayer_uptime_seconds ${metrics.uptimeSeconds}
`;
    
    res.set('Content-Type', 'text/plain');
    res.send(prometheusMetrics.trim());
  }
  
  /**
   * JSON metrics handler
   */
  private async handleMetricsJson(req: Request, res: Response): Promise<void> {
    const metrics = await this.collectMetrics();
    res.json(metrics);
  }
  
  /**
   * Collect metrics from database
   */
  private async collectMetrics(): Promise<Metrics> {
    // Get settlement counts
    const settlements = db['db'].prepare('SELECT status, COUNT(*) as count FROM settlements GROUP BY status').all() as any[];
    
    const totalSettlements = settlements.reduce((sum, s) => sum + s.count, 0);
    const successfulSettlements = settlements.find(s => s.status === 'confirmed')?.count || 0;
    const failedSettlements = settlements.find(s => s.status === 'failed')?.count || 0;
    const pendingSettlements = settlements.find(s => s.status === 'pending')?.count || 0;
    
    // Get order counts
    const orderStats = db['db'].prepare('SELECT COUNT(*) as total, SUM(executed) as executed FROM orders').get() as any;
    
    // Get batch counts
    const batchStats = db['db'].prepare('SELECT COUNT(*) as total, SUM(settled) as settled FROM batches').get() as any;
    
    // Calculate average settlement time
    const avgSettlementTime = db['db'].prepare(`
      SELECT AVG(confirmedAt - createdAt) as avg 
      FROM settlements 
      WHERE status = 'confirmed' AND confirmedAt IS NOT NULL
    `).get() as any;
    
    // Calculate average gas used
    const avgGasUsed = db['db'].prepare(`
      SELECT AVG(gasUsed) as avg 
      FROM settlements 
      WHERE status = 'confirmed' AND gasUsed IS NOT NULL
    `).get() as any;
    
    return {
      totalSettlements,
      successfulSettlements,
      failedSettlements,
      pendingSettlements,
      totalOrders: orderStats?.total || 0,
      executedOrders: orderStats?.executed || 0,
      totalBatches: batchStats?.total || 0,
      settledBatches: batchStats?.settled || 0,
      averageSettlementTimeMs: avgSettlementTime?.avg || 0,
      averageGasUsed: avgGasUsed?.avg || 0,
      uptimeSeconds: Math.floor((Date.now() - this.startTime) / 1000),
      startTime: this.startTime,
    };
  }
}

export const metrics = new MetricsCollector();
