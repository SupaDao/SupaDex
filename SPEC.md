# Technical Specification

## Table of Contents

- [System Overview](#system-overview)
- [Concentrated Liquidity AMM](#concentrated-liquidity-amm)
- [Batch Auction System](#batch-auction-system)
- [Limit Order Book](#limit-order-book)
- [Governance](#governance)
- [Security Model](#security-model)
- [Upgrade Procedures](#upgrade-procedures)
- [Integration Guide](#integration-guide)

## System Overview

The Hybrid DEX combines three trading mechanisms:

1. **Concentrated Liquidity AMM**: For continuous liquidity provision and instant swaps
2. **Batch Auctions**: For MEV-resistant limit orders with fair price discovery
3. **Limit Order Book**: For gas-optimized on-chain limit orders

### Design Principles

- **Capital Efficiency**: Concentrated liquidity maximizes capital utilization
- **MEV Resistance**: Commit-reveal scheme prevents front-running
- **Gas Optimization**: Bitmap storage, calldata compression, batch operations
- **Upgradeability**: UUPS pattern for all core contracts
- **Composability**: Standard interfaces for easy integration

## Concentrated Liquidity AMM

### Tick System

The AMM uses a tick-based system where each tick represents a 0.01% price movement:

```
price(tick) = 1.0001^tick
```

**Tick Spacing**: Determines granularity of liquidity positions

- 500 bps fee → 10 tick spacing
- 3000 bps fee → 60 tick spacing
- 10000 bps fee → 200 tick spacing

### Liquidity Math

**Virtual Liquidity**:

```
L = sqrt(x * y)
```

**Price Representation**:

```
sqrtPriceX96 = sqrt(price) * 2^96
```

**Amount Calculations**:

```
Δx = L * (sqrt(P_b) - sqrt(P_a)) / (sqrt(P_a) * sqrt(P_b))
Δy = L * (sqrt(P_b) - sqrt(P_a))
```

### Fee Calculation

**Fee Growth Tracking**:

- Global fee accumulators: `feeGrowthGlobal0X128`, `feeGrowthGlobal1X128`
- Per-position tracking using inside/outside pattern
- Q128.128 fixed-point precision

**Fee Formula**:

```
fees_owed = liquidity * (feeGrowthInside_current - feeGrowthInside_last) / 2^128
```

### Swap Algorithm

1. **Initialize**: Set starting price and amount remaining
2. **Loop**: While amount remaining > 0:
   - Find next initialized tick
   - Compute swap step to next tick
   - Update state and cross tick if needed
3. **Finalize**: Transfer tokens and update global state

**Tick Crossing**:

- Update tick liquidity delta
- Flip tick in bitmap
- Update fee growth outside values

## Batch Auction System

### Commit-Reveal Mechanism

**Phase 1: Commit (Open)**

- Users submit order commitments: `commitment = keccak256(order || salt)`
- Optional: Lock tokens for guaranteed execution
- Duration: Configurable (e.g., 10 blocks)

**Phase 2: Reveal (Revealing)**

- Users reveal actual order details
- Relayer aggregates all revealed orders
- Validates orders (expiry, amount, price)

**Phase 3: Settlement (Settled)**

- Relayer calculates clearing price
- Builds merkle tree of orders
- Submits settlement transaction with proofs
- Orders executed at uniform clearing price

### Clearing Price Algorithm

**Uniform Price Auction**:

1. Sort buy orders by price (descending)
2. Sort sell orders by price (ascending)
3. Find intersection of supply and demand
4. Clearing price = midpoint of overlap

```
maxBuyPrice = highest buy limit price
minSellPrice = lowest sell limit price

if maxBuyPrice >= minSellPrice:
    clearingPrice = (maxBuyPrice + minSellPrice) / 2
```

### Merkle Proof Settlement

**Tree Construction**:

```
leaves = [hash(order1), hash(order2), ...]
root = buildMerkleTree(leaves)
```

**On-Chain Verification**:

- Relayer submits: clearing price, order list, merkle proofs
- Contract verifies each proof against root
- Executes orders at clearing price

**Gas Optimization**:

- Off-chain aggregation reduces on-chain computation
- Merkle proofs enable efficient verification
- Batch execution amortizes costs

## Limit Order Book

### Order Structure

**Compact Encoding**:

```solidity
struct CompactOrder {
    uint64 nonce;
    uint64 expiry;
    uint128 amount;
    uint128 limitPrice;
    uint8 side;  // 0 = buy, 1 = sell
}
```

**Calldata Savings**: ~40% reduction vs standard ABI encoding

### Order Matching

**Maker/Taker Model**:

- **Makers**: Place limit orders, provide liquidity
- **Takers**: Execute orders at maker's price

**Execution Logic**:

1. Validate order exists and not cancelled
2. Check expiry and remaining amount
3. Calculate fill amount (respecting partial fills)
4. Transfer tokens with fee deduction
5. Update order status

### Fee Structure

- Protocol fee: Configurable (default 0.3%)
- Deducted from taker's received amount
- Accumulated for later collection

## Governance

### Timelock Mechanism

**Delay Periods**:

- Localhost: 1 hour
- Testnet: 6 hours
- Mainnet: 2 days

**Protected Operations**:

- Contract upgrades
- Parameter changes
- Role grants/revokes

### Upgrade Process

1. **Propose**: Submit upgrade transaction to timelock
2. **Wait**: Delay period for community review
3. **Execute**: After delay, execute upgrade
4. **Verify**: Confirm upgrade success

## Security Model

### Access Control Matrix

| Role               | Contracts                | Permissions                     |
| ------------------ | ------------------------ | ------------------------------- |
| DEFAULT_ADMIN_ROLE | All                      | Manage roles, update parameters |
| UPGRADER_ROLE      | Factory, Pools, Auctions | Upgrade implementations         |
| RELAYER_ROLE       | BatchAuction             | Settle batches                  |
| PAUSER_ROLE        | BatchAuction             | Emergency pause                 |
| FEE_COLLECTOR_ROLE | LimitOrderBook           | Collect fees                    |

### Reentrancy Protection

- `ReentrancyGuard` on all state-changing functions
- Checks-Effects-Interactions pattern
- No external calls before state updates

### Oracle Manipulation Prevention

**OracleGuard**:

- TWAP deviation checks
- Maximum price movement limits
- Configurable thresholds per pool

**Protection**:

```solidity
function checkPriceDeviation(
    address pool,
    uint160 sqrtPriceX96,
    uint32 twapPeriod,
    uint16 maxDeviationBps
) external view
```

### MEV Resistance

**Batch Auctions**:

- Commit-reveal prevents front-running
- Uniform price ensures fairness
- Relayer cannot manipulate clearing price

**AMM**:

- Slippage protection
- Deadline checks
- Price limit parameters

### Integer Safety

- Solidity 0.8+ automatic overflow checks
- Explicit bounds checking for critical operations
- Full-precision math libraries (FullMath.sol)

## Upgrade Procedures

### UUPS Upgrade Workflow

**Pre-Upgrade**:

1. Deploy new implementation contract
2. Verify implementation on Etherscan
3. Test upgrade on testnet
4. Validate storage layout compatibility
5. Prepare upgrade transaction

**Upgrade Execution**:

```solidity
// Via timelock
Factory(proxy).upgradeToAndCall(newImplementation, "");
```

**Post-Upgrade**:

1. Verify proxy points to new implementation
2. Run smoke tests
3. Monitor for issues
4. Update deployment manifest

### Storage Layout Compatibility

**Rules**:

- Never remove or reorder existing variables
- Only append new variables
- Use storage gaps for future additions
- Test with `forge inspect storage-layout`

**Example**:

```solidity
contract MyContract {
    uint256 public existingVar;
    // ... existing variables ...

    uint256[50] private __gap;  // Reserve space
}
```

### Rollback Procedure

If upgrade fails:

1. **Immediate**: Call `upgradeToAndCall` with previous implementation
2. **Verify**: Confirm rollback successful
3. **Investigate**: Analyze failure cause
4. **Fix**: Address issues before retry

### Testing Upgrades

```bash
# Test upgrade on local fork
forge script script/UUPSUpgrade.s.sol \
  --fork-url $MAINNET_RPC_URL \
  --private-key $TEST_KEY

# Verify storage layout
forge inspect ConcentratedPool storage-layout
```

## Integration Guide

### Frontend Integration

**Web3 Provider Setup**:

```javascript
import { ethers } from "ethers";

const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);
```

**Creating a Pool**:

```javascript
const tx = await factory.createPool(
	tokenA,
	tokenB,
	3000 // 0.3% fee
);
await tx.wait();
```

**Executing a Swap**:

```javascript
const router = new ethers.Contract(ROUTER_ADDRESS, ROUTER_ABI, signer);

// Approve tokens
await token0.approve(router.address, amountIn);

// Execute swap
const tx = await router.exactInputSingle({
	tokenIn: token0.address,
	tokenOut: token1.address,
	fee: 3000,
	recipient: await signer.getAddress(),
	amountIn: ethers.parseEther("1"),
	amountOutMinimum: ethers.parseUnits("1400", 6),
	sqrtPriceLimitX96: 0,
});

await tx.wait();
```

### Backend Integration

**Event Monitoring**:

```typescript
const pool = new ethers.Contract(POOL_ADDRESS, POOL_ABI, provider);

// Listen for swaps
pool.on(
	"Swap",
	(sender, recipient, amount0, amount1, sqrtPriceX96, liquidity, tick) => {
		console.log("Swap executed:", {
			sender,
			recipient,
			amount0: amount0.toString(),
			amount1: amount1.toString(),
			price: sqrtPriceX96.toString(),
			tick,
		});
	}
);
```

**Price Queries**:

```typescript
const slot0 = await pool.slot0();
const currentPrice = slot0.sqrtPriceX96;
const currentTick = slot0.tick;

// Convert to human-readable price
const price = (Number(currentPrice) / 2 ** 96) ** 2;
```

### Relayer Integration

See [script/relayer/README.md](../script/relayer/README.md) for complete relayer integration guide.

**Key Steps**:

1. Deploy contracts and grant RELAYER_ROLE
2. Configure relayer with RPC endpoint and private key
3. Start relayer service
4. Monitor settlement transactions

### Third-Party Integration

**Aggregators**:

- Implement standard Router interface
- Query pool prices via `slot0()`
- Execute swaps via `exactInputSingle()`

**Analytics**:

- Index events (Swap, Mint, Burn, etc.)
- Track TVL, volume, fees
- Calculate APRs for LPs

**Wallets**:

- Integrate Router for swaps
- Display LP positions from NFTs
- Show pending orders from order books

## Appendix

### Constants

```solidity
// Tick constants
int24 constant MIN_TICK = -887272;
int24 constant MAX_TICK = 887272;

// Price constants
uint160 constant MIN_SQRT_RATIO = 4295128739;
uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

// Fee tiers
uint24 constant FEE_LOW = 500;      // 0.05%
uint24 constant FEE_MEDIUM = 3000;  // 0.3%
uint24 constant FEE_HIGH = 10000;   // 1%
```

### Formulas Reference

**Price to Tick**:

```
tick = floor(log(price) / log(1.0001))
```

**Tick to Price**:

```
price = 1.0001^tick
```

**Liquidity from Amounts**:

```
L = sqrt(x * y)
```

**Amount0 from Liquidity**:

```
amount0 = L * (sqrt(P_upper) - sqrt(P_lower)) / (sqrt(P_lower) * sqrt(P_upper))
```

**Amount1 from Liquidity**:

```
amount1 = L * (sqrt(P_upper) - sqrt(P_lower))
```

### Error Codes

| Error | Description                                  |
| ----- | -------------------------------------------- |
| `IA`  | Invalid address (zero address or same token) |
| `ZA`  | Zero address not allowed                     |
| `PE`  | Pool already exists                          |
| `AE`  | Auction already exists                       |
| `ZI`  | Zero implementation address                  |
| `TLU` | Tick lower >= tick upper                     |
| `TLM` | Tick lower < MIN_TICK                        |
| `TUM` | Tick upper > MAX_TICK                        |
| `LOK` | Locked (reentrancy)                          |

### Gas Optimization Tips

1. **Use Compact Encoding**: Save ~40% on calldata
2. **Batch Operations**: Amortize fixed costs
3. **Approve Once**: Use `type(uint256).max`
4. **Reuse Positions**: Add to existing tick ranges
5. **Limit Tick Crossings**: Stay within single tick when possible

---

For more information, see:

- [README.md](./README.md) - Getting started
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Deep dive
- [CONTRIBUTING.md](./CONTRIBUTING.md) - Development guide
- [SECURITY.md](./SECURITY.md) - Security details
