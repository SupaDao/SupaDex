# Contributing to Hybrid DEX

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Testing Guidelines](#testing-guidelines)
- [Pull Request Process](#pull-request-process)
- [Release Process](#release-process)

## Getting Started

### Prerequisites

- **Foundry**: Latest version (`foundryup`)
- **Node.js**: v18+ (for relayer and scripts)
- **Git**: For version control
- **Code Editor**: VSCode recommended with Solidity extension

### First-Time Setup

```bash
# Clone repository
git clone <repo-url>
cd dex

# Install Foundry dependencies
forge install

# Install Node dependencies (for relayer)
cd script/relayer
npm install
cd ../..

# Build contracts
forge build

# Run tests
forge test
```

## Development Setup

### Environment Configuration

Create `.env` file:

```bash
# RPC endpoints
MAINNET_RPC_URL=https://...
SEPOLIA_RPC_URL=https://...

# Private keys (NEVER commit these)
PRIVATE_KEY=0x...
DEPLOYER_PRIVATE_KEY=0x...

# API keys
ETHERSCAN_API_KEY=...
```

### IDE Setup (VSCode)

Recommended extensions:

- `juanblanco.solidity` - Solidity support
- `tintinweb.solidity-visual-auditor` - Security auditing
- `esbenp.prettier-vscode` - Code formatting

Settings (`.vscode/settings.json`):

```json
{
	"solidity.compileUsingRemoteVersion": "v0.8.19",
	"solidity.formatter": "forge",
	"[solidity]": {
		"editor.defaultFormatter": "JuanBlanco.solidity"
	}
}
```

## Project Structure

```
dex/
├── contracts/
│   ├── core/              # Core trading contracts
│   ├── periphery/         # Helper contracts
│   ├── libraries/         # Shared libraries
│   ├── governance/        # Governance contracts
│   ├── upgrades/          # Upgrade infrastructure
│   └── interfaces/        # Contract interfaces
├── script/
│   ├── Deploy.s.sol       # Deployment scripts
│   ├── Config.s.sol       # Network configurations
│   └── relayer/           # Relayer service
├── test/
│   ├── unit/              # Unit tests
│   ├── fuzz/              # Fuzz tests
│   ├── invariant/         # Invariant tests
│   └── fork/              # Fork tests
├── docs/                  # Documentation
└── examples/              # Integration examples
```

### File Naming Conventions

- **Contracts**: PascalCase (e.g., `ConcentratedPool.sol`)
- **Libraries**: PascalCase (e.g., `TickMath.sol`)
- **Tests**: PascalCase with `.t.sol` suffix (e.g., `ConcentratedPool.t.sol`)
- **Scripts**: PascalCase with `.s.sol` suffix (e.g., `Deploy.s.sol`)
- **Interfaces**: PascalCase with `I` prefix (e.g., `IFactory.sol`)

## Coding Standards

### Solidity Style Guide

Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html) with these additions:

**Imports**:

```solidity
// Group imports: external, internal, interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {TickMath} from "./libraries/TickMath.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

import {IFactory} from "./interfaces/IFactory.sol";
```

**Function Order**:

1. Constructor
2. External functions
3. Public functions
4. Internal functions
5. Private functions

**NatSpec Comments**:

```solidity
/// @notice Swaps tokens in the pool
/// @param recipient Address to receive output tokens
/// @param zeroForOne Direction of swap (true = token0 -> token1)
/// @param amountSpecified Amount to swap (negative for exact output)
/// @param sqrtPriceLimitX96 Price limit for the swap
/// @param data Callback data
/// @return amount0 Amount of token0
/// @return amount1 Amount of token1
function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
) external returns (int256 amount0, int256 amount1);
```

**Error Handling**:

```solidity
// Use custom errors (gas efficient)
error InvalidTick(int24 tick);
error InsufficientLiquidity();

// Revert with custom errors
if (tick < MIN_TICK || tick > MAX_TICK) {
    revert InvalidTick(tick);
}
```

### TypeScript Style Guide

- Use TypeScript strict mode
- Prefer `const` over `let`
- Use async/await over promises
- Document public functions with JSDoc

```typescript
/**
 * Calculates clearing price for batch auction
 * @param buyOrders - Array of buy orders
 * @param sellOrders - Array of sell orders
 * @returns Clearing price or 0 if no match
 */
export function calculateClearingPrice(
	buyOrders: Order[],
	sellOrders: Order[]
): bigint {
	// Implementation
}
```

## Testing Guidelines

### Test Coverage Requirements

- **Minimum**: 80% line coverage
- **Target**: 90% line coverage
- **Critical paths**: 100% coverage

### Test Types

**Unit Tests**:

```solidity
function testSwapExactInput() public {
    // Setup
    uint256 amountIn = 1 ether;

    // Execute
    (int256 amount0, int256 amount1) = pool.swap(
        address(this),
        true,
        int256(amountIn),
        0,
        ""
    );

    // Assert
    assertGt(uint256(-amount1), 0, "Should receive tokens");
}
```

**Fuzz Tests**:

```solidity
function testFuzzSwap(uint256 amountIn) public {
    // Bound inputs
    amountIn = bound(amountIn, 1e6, 1000 ether);

    // Test with random inputs
    pool.swap(address(this), true, int256(amountIn), 0, "");
}
```

**Invariant Tests**:

```solidity
function invariant_poolBalanceMatchesState() public {
    uint256 balance0 = token0.balanceOf(address(pool));
    uint256 balance1 = token1.balanceOf(address(pool));

    // Pool balances should always match internal accounting
    assertEq(balance0, pool.balance0());
    assertEq(balance1, pool.balance1());
}
```

### Running Tests

```bash
# All tests
forge test

# Specific test file
forge test --match-path test/ConcentratedPool.t.sol

# Specific test function
forge test --match-test testSwapExactInput

# With gas report
forge test --gas-report

# With coverage
forge coverage

# Fuzz tests (more runs)
forge test --fuzz-runs 10000

# Fork tests
forge test --fork-url $MAINNET_RPC_URL
```

## Pull Request Process

### Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation
- `refactor/description` - Code refactoring
- `test/description` - Test additions

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add flash loan functionality
fix: correct fee calculation in swap
docs: update README with deployment guide
test: add fuzz tests for liquidity math
refactor: optimize tick bitmap storage
```

### PR Checklist

Before submitting:

- [ ] Code compiles without errors
- [ ] All tests pass
- [ ] New tests added for new features
- [ ] Coverage meets requirements (80%+)
- [ ] NatSpec comments added
- [ ] Gas optimizations considered
- [ ] Security implications reviewed
- [ ] Documentation updated

### Code Review

All PRs require:

- At least 1 approval from maintainer
- All CI checks passing
- No merge conflicts
- Up-to-date with main branch

## Release Process

### Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **Major**: Breaking changes
- **Minor**: New features (backwards compatible)
- **Patch**: Bug fixes

### Release Checklist

1. **Pre-Release**

   - [ ] All tests passing
   - [ ] Documentation updated
   - [ ] CHANGELOG.md updated
   - [ ] Version bumped in contracts

2. **Testnet Deployment**

   - [ ] Deploy to Sepolia
   - [ ] Verify contracts
   - [ ] Test all functionality
   - [ ] Monitor for 48 hours

3. **Security**

   - [ ] Security audit completed
   - [ ] Audit issues resolved
   - [ ] Bug bounty program active

4. **Mainnet Deployment**

   - [ ] Multisig setup
   - [ ] Timelock configured
   - [ ] Deploy contracts
   - [ ] Verify on Etherscan
   - [ ] Transfer ownership to multisig

5. **Post-Deployment**
   - [ ] Monitor for anomalies
   - [ ] Update documentation
   - [ ] Announce release
   - [ ] Tag release in Git

## Code of Conduct

### Our Standards

- Be respectful and inclusive
- Welcome newcomers
- Focus on constructive feedback
- Prioritize security and quality

### Unacceptable Behavior

- Harassment or discrimination
- Trolling or insulting comments
- Publishing private information
- Other unprofessional conduct

## Getting Help

- **Discord**: [discord.gg/hybriddex](https://discord.gg/hybriddex)
- **GitHub Issues**: For bugs and feature requests
- **GitHub Discussions**: For questions and ideas

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to Hybrid DEX! 🚀
