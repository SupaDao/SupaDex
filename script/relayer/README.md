# DEX Relayer Service

Automated relayer service for settling batch auctions in the DEX.

## Features

- **Order Aggregation**: Listens for order commitment and reveal events
- **Merkle Tree Construction**: Builds merkle trees and generates proofs for efficient on-chain verification
- **Automated Settlement**: Monitors batch states and submits settlement transactions
- **Error Handling**: Retry logic with exponential backoff for failed transactions
- **Monitoring**: Health checks and Prometheus-compatible metrics
- **Database**: SQLite for order and batch tracking

## Prerequisites

- Node.js 18+ and npm
- Deployed DEX contracts
- RPC endpoint (Infura, Alchemy, or local node)
- Relayer wallet with ETH for gas and RELAYER_ROLE granted

## Installation

```bash
cd script/relayer
npm install
```

## Configuration

Copy the example environment file and configure:

```bash
cp .env.example .env
```

Edit `.env` with your settings:

```env
# Network
NETWORK=localhost
RPC_URL=http://localhost:8545
CHAIN_ID=31337

# Relayer
RELAYER_PRIVATE_KEY=0x...
RELAYER_ADDRESS=0x...

# Gas limits
MAX_GAS_PRICE_GWEI=100
MAX_PRIORITY_FEE_GWEI=2

# Monitoring
ENABLE_METRICS=true
METRICS_PORT=9090
```

## Usage

### Development

```bash
npm run dev
```

### Production

```bash
# Build
npm run build

# Start
npm start
```

### Docker

```bash
# Build image
docker build -t dex-relayer .

# Run container
docker run -d \
  --name dex-relayer \
  --env-file .env \
  -p 9090:9090 \
  -v $(pwd)/relayer.db:/app/relayer.db \
  dex-relayer
```

## Monitoring

### Health Check

```bash
curl http://localhost:8080/health
```

### Metrics (Prometheus format)

```bash
curl http://localhost:9090/metrics
```

### Metrics (JSON)

```bash
curl http://localhost:9090/metrics/json
```

## Architecture

```
src/
├── index.ts          # Main entry point
├── config.ts         # Configuration management
├── db.ts             # SQLite database operations
├── logger.ts         # Structured logging
├── aggregator.ts     # Order aggregation from events
├── merkle.ts         # Merkle tree construction
├── settlement.ts     # Settlement transaction builder
├── monitor.ts        # Batch state monitoring
├── retry.ts          # Retry logic with backoff
└── metrics.ts        # Metrics collection
```

## Database Schema

### Orders Table
- `orderHash`: Unique order identifier
- `batchId`: Batch the order belongs to
- `trader`: Order creator address
- `nonce`, `expiry`, `amount`, `limitPrice`, `side`: Order parameters
- `revealed`, `executed`: Order status flags

### Batches Table
- `batchId`: Unique batch identifier
- `startBlock`, `endBlock`: Batch block range
- `clearingPrice`: Calculated clearing price
- `ordersRoot`: Merkle root of orders
- `settled`: Settlement status
- `txHash`: Settlement transaction hash

### Settlements Table
- `batchId`: Batch being settled
- `txHash`: Transaction hash
- `status`: pending/confirmed/failed
- `gasUsed`: Gas consumed
- `error`: Error message if failed

## Troubleshooting

### Relayer has no ETH

The relayer needs ETH to pay for gas. Fund the relayer address:

```bash
# Check balance
cast balance $RELAYER_ADDRESS --rpc-url $RPC_URL

# Send ETH (from another account)
cast send $RELAYER_ADDRESS --value 1ether --rpc-url $RPC_URL --private-key $FUNDER_KEY
```

### Relayer doesn't have RELAYER_ROLE

Grant the role using the Factory owner account:

```solidity
// In Foundry console or script
BatchAuction auction = BatchAuction(AUCTION_ADDRESS);
auction.grantRole(auction.RELAYER_ROLE(), RELAYER_ADDRESS);
```

### RPC connection issues

- Check RPC_URL is correct
- Verify RPC endpoint is accessible
- Configure BACKUP_RPC_URL for failover

### Database locked

If you see "database is locked" errors:

```bash
# Stop the relayer
pkill -f "node.*relayer"

# Remove lock file
rm relayer.db-wal relayer.db-shm

# Restart
npm start
```

## Development

### Running Tests

```bash
npm test
```

### Linting

```bash
npm run lint
```

### Formatting

```bash
npm run format
```

## Production Deployment

### Systemd Service

Create `/etc/systemd/system/dex-relayer.service`:

```ini
[Unit]
Description=DEX Relayer Service
After=network.target

[Service]
Type=simple
User=relayer
WorkingDirectory=/opt/dex-relayer
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl enable dex-relayer
sudo systemctl start dex-relayer
sudo systemctl status dex-relayer
```

### Monitoring with Prometheus

Add to `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'dex-relayer'
    static_configs:
      - targets: ['localhost:9090']
```

### Alerting

Configure alerts for:
- Settlement failures
- Low wallet balance
- RPC connection issues
- High gas prices

## Security

- **Private Key**: Never commit `.env` file. Use secrets management in production.
- **Gas Limits**: Configure MAX_GAS_PRICE_GWEI to prevent excessive costs.
- **Access Control**: Ensure only authorized addresses have RELAYER_ROLE.
- **Monitoring**: Set up alerts for unusual activity.

## License

MIT
