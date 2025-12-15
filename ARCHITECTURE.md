# Architecture Deep Dive

## System Design

The Hybrid DEX implements a modular architecture with three core trading mechanisms operating independently but sharing common infrastructure.

### Design Principles

1. **Modularity**: Each component (AMM, Auction, Order Book) is self-contained
2. **Upgradeability**: UUPS pattern allows non-disruptive upgrades
3. **Gas Efficiency**: Bitmap storage, calldata compression, batch operations
4. **Security**: Defense in depth with multiple protection layers
5. **Composability**: Standard interfaces for ecosystem integration

## Contract Architecture

### Proxy Pattern (UUPS)

```
┌─────────────────┐
│  ERC1967Proxy   │  ← User calls this address
└────────┬────────┘
         │ delegatecall
         ▼
┌─────────────────┐
│ Implementation  │  ← Logic contract
│  (Upgradeable)  │
└─────────────────┘
```

**Benefits**:

- Upgrade logic without changing address
- Lower deployment costs vs Transparent Proxy
- Upgrade authorization in implementation

**Storage Layout**:

- Implementation address: `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
- Admin slot: `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`

### Core Contracts

#### Factory

**Responsibilities**:

- Deploy pools and auctions as proxies
- Manage implementation contracts
- Enforce fee tiers and tick spacing

**Storage**:

```solidity
mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
mapping(address => mapping(address => address)) public getAuction;
address public concentratedPoolImplementation;
address public batchAuctionImplementation;
```

#### ConcentratedPool

**Data Structures**:

```solidity
struct Slot0 {
    uint160 sqrtPriceX96;      // Current price
    int24 tick;                 // Current tick
    uint16 observationIndex;    // Oracle index
    uint16 observationCardinality;
    uint16 observationCardinalityNext;
    uint8 feeProtocol;         // Protocol fee
    bool unlocked;             // Reentrancy lock
}

struct Position {
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
}

struct Tick {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    int56 tickCumulativeOutside;
    uint160 secondsPerLiquidityOutsideX128;
    uint32 secondsOutside;
    bool initialized;
}
```

**Tick Bitmap**:

- 256 ticks per word
- Compressed storage: `mapping(int16 => uint256)`
- O(1) next tick lookup

## Algorithms

### Swap Algorithm

```
function swap(amountSpecified, sqrtPriceLimitX96):
    state = initializeState()

    while state.amountSpecifiedRemaining != 0 and state.sqrtPriceX96 != sqrtPriceLimitX96:
        step = computeNextStep(state)

        (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) =
            computeSwapStep(
                state.sqrtPriceX96,
                step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            )

        state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount)
        state.amountCalculated += step.amountOut

        if state.sqrtPriceX96 == step.sqrtPriceNextX96:
            crossTick(step.tickNext)
            state.liquidity = applyLiquidityDelta(state.liquidity, step.tickNext)

    return (state.amount0, state.amount1)
```

### Liquidity Math

**Adding Liquidity**:

```
Given: tickLower, tickUpper, amount0Desired, amount1Desired

1. Calculate liquidity from amount0:
   L0 = amount0 * sqrt(P_lower) * sqrt(P_upper) / (sqrt(P_upper) - sqrt(P_lower))

2. Calculate liquidity from amount1:
   L1 = amount1 / (sqrt(P_upper) - sqrt(P_lower))

3. Take minimum:
   L = min(L0, L1)

4. Calculate actual amounts:
   amount0 = L * (sqrt(P_upper) - sqrt(P_lower)) / (sqrt(P_lower) * sqrt(P_upper))
   amount1 = L * (sqrt(P_upper) - sqrt(P_lower))
```

### Clearing Price Calculation

**Uniform Price Auction**:

```
function calculateClearingPrice(buyOrders, sellOrders):
    // Sort orders
    buyOrders.sort(by: price DESC)
    sellOrders.sort(by: price ASC)

    // Find intersection
    maxBuyPrice = buyOrders[0].limitPrice
    minSellPrice = sellOrders[0].limitPrice

    if maxBuyPrice >= minSellPrice:
        return (maxBuyPrice + minSellPrice) / 2
    else:
        return 0  // No match
```

### Merkle Tree Construction

```
function buildMerkleTree(leaves):
    if leaves.length == 0:
        return null

    layers = [leaves.sort()]

    while layers[last].length > 1:
        currentLayer = layers[last]
        nextLayer = []

        for i in range(0, currentLayer.length, 2):
            if i + 1 < currentLayer.length:
                hash = keccak256(sort(currentLayer[i], currentLayer[i+1]))
                nextLayer.append(hash)
            else:
                nextLayer.append(currentLayer[i])

        layers.append(nextLayer)

    return layers[last][0]  // root
```

## Gas Optimizations

### Bitmap Storage

**Traditional Approach**:

```solidity
mapping(int24 => bool) public initializedTicks;  // 20k gas per tick
```

**Optimized Approach**:

```solidity
mapping(int16 => uint256) public tickBitmap;  // 5k gas per 256 ticks
```

**Savings**: 75% reduction in gas costs for tick initialization.

### Calldata Compression

**Standard ABI**:

```
Order: 5 * 32 bytes = 160 bytes
Cost: 160 * 16 gas = 2,560 gas
```

**Compact Encoding**:

```
CompactOrder: 8 + 8 + 16 + 16 + 1 = 49 bytes
Cost: 49 * 16 gas = 784 gas
```

**Savings**: 69% reduction in calldata costs.

### Storage Patterns

**Slot Packing**:

```solidity
struct Slot0 {
    uint160 sqrtPriceX96;  // 20 bytes
    int24 tick;            // 3 bytes
    uint16 observationIndex;  // 2 bytes
    // ... fits in 32 bytes
}
```

**Benefits**: Single SLOAD instead of multiple.

## Security Architecture

### Defense Layers

1. **Access Control**: Role-based permissions
2. **Reentrancy Guards**: Prevent reentrant calls
3. **Integer Safety**: Solidity 0.8+ overflow checks
4. **Oracle Protection**: TWAP deviation limits
5. **Upgrade Safety**: Timelock + storage validation

### Attack Vectors & Mitigations

| Attack              | Mitigation                     |
| ------------------- | ------------------------------ |
| Front-running       | Commit-reveal, slippage limits |
| Sandwich attacks    | MEV-resistant auctions         |
| Oracle manipulation | TWAP checks, deviation bounds  |
| Flash loan attacks  | No spot balance reliance       |
| Reentrancy          | ReentrancyGuard, CEI pattern   |
| Integer overflow    | Solidity 0.8+, bounds checking |

### Upgrade Safety

**Pre-Upgrade Checks**:

1. Storage layout compatibility
2. Implementation validation
3. Testnet deployment
4. Community review period

**Post-Upgrade Validation**:

1. Smoke tests
2. State verification
3. Monitoring for anomalies

## Performance Characteristics

### Time Complexity

| Operation        | Complexity | Notes               |
| ---------------- | ---------- | ------------------- |
| Swap (no cross)  | O(1)       | Single tick         |
| Swap (n crosses) | O(n)       | n tick crossings    |
| Next tick lookup | O(1)       | Bitmap optimization |
| Add liquidity    | O(1)       | Constant operations |
| Remove liquidity | O(1)       | Constant operations |
| Order placement  | O(1)       | Hash table insert   |
| Order execution  | O(1)       | Direct lookup       |
| Batch settlement | O(n)       | n orders to verify  |

### Space Complexity

| Data Structure | Size      | Notes                  |
| -------------- | --------- | ---------------------- |
| Position       | 160 bytes | Per position           |
| Tick           | 256 bytes | Per initialized tick   |
| Bitmap word    | 32 bytes  | Per 256 ticks          |
| Order          | 64 bytes  | Compact encoding       |
| Batch          | Variable  | Depends on order count |

## Integration Patterns

### Event-Driven Architecture

```typescript
// Listen for events
pool.on("Swap", handleSwap);
pool.on("Mint", handleMint);
pool.on("Burn", handleBurn);

// Process events
function handleSwap(event) {
	updateDatabase(event);
	notifyUsers(event);
	updateAnalytics(event);
}
```

### Price Feeds

```typescript
// Get current price
const slot0 = await pool.slot0();
const sqrtPriceX96 = slot0.sqrtPriceX96;
const price = (Number(sqrtPriceX96) / 2 ** 96) ** 2;

// Get TWAP
const twap = await oracle.consult(pool, period);
```

### Liquidity Provision

```typescript
// Calculate optimal amounts
const { amount0, amount1 } = calculateLiquidityAmounts(
	currentPrice,
	tickLower,
	tickUpper,
	liquidityDesired
);

// Add liquidity
await pool.mint(recipient, tickLower, tickUpper, liquidity, data);
```

## Future Enhancements

### V2 Features

- **Flash Loans**: Uncollateralized loans within single transaction
- **TWAP Oracle**: Time-weighted average price oracle
- **Multi-hop Routing**: Optimal path finding across multiple pools
- **Governance Token**: Decentralized protocol governance

### Scalability

- **Layer 2**: Deploy on Arbitrum, Optimism
- **Cross-chain**: Bridge liquidity across chains
- **Sharding**: Separate pools by asset class

---

For more details, see:

- [SPEC.md](./SPEC.md) - Technical specification
- [README.md](./README.md) - User guide
- [CONTRIBUTING.md](./CONTRIBUTING.md) - Development guide
