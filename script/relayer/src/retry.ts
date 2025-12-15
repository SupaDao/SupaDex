import { logger } from './logger';
import { config } from './config';

export interface RetryOptions {
  maxRetries?: number;
  delayMs?: number;
  backoffMultiplier?: number;
  onRetry?: (attempt: number, error: any) => void;
}

/**
 * Retry a function with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxRetries: number = config.maxRetries,
  options?: RetryOptions
): Promise<T | null> {
  const opts = {
    maxRetries: options?.maxRetries || maxRetries,
    delayMs: options?.delayMs || config.retryDelayMs,
    backoffMultiplier: options?.backoffMultiplier || config.retryBackoffMultiplier,
    onRetry: options?.onRetry,
  };
  
  let lastError: any;
  
  for (let attempt = 0; attempt <= opts.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error: any) {
      lastError = error;
      
      if (attempt === opts.maxRetries) {
        logger.error({ error, attempt }, 'Max retries reached');
        break;
      }
      
      // Check if error is retryable
      if (!isRetryableError(error)) {
        logger.error({ error }, 'Non-retryable error encountered');
        throw error;
      }
      
      const delay = opts.delayMs * Math.pow(opts.backoffMultiplier, attempt);
      
      logger.warn({
        error: error.message,
        attempt: attempt + 1,
        maxRetries: opts.maxRetries,
        delayMs: delay,
      }, 'Retrying after error');
      
      if (opts.onRetry) {
        opts.onRetry(attempt + 1, error);
      }
      
      await sleep(delay);
    }
  }
  
  return null;
}

/**
 * Check if an error is retryable
 */
function isRetryableError(error: any): boolean {
  // Network errors
  if (error.code === 'NETWORK_ERROR' || error.code === 'TIMEOUT') {
    return true;
  }
  
  // RPC errors
  if (error.code === 'SERVER_ERROR' || error.code === -32603) {
    return true;
  }
  
  // Nonce errors (can retry with updated nonce)
  if (error.code === 'NONCE_EXPIRED' || error.message?.includes('nonce')) {
    return true;
  }
  
  // Gas price errors
  if (error.code === 'INSUFFICIENT_FUNDS' || error.message?.includes('gas')) {
    return false; // Don't retry if we don't have enough funds
  }
  
  // Already settled
  if (error.message?.includes('AlreadySettled')) {
    return false;
  }
  
  // Default to retryable for unknown errors
  return true;
}

/**
 * Sleep for a specified duration
 */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
