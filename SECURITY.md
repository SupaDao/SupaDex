# Security

## Reporting Security Issues

**DO NOT** create a public GitHub issue for security vulnerabilities.

Instead, please report security issues to: **security@hybriddex.io**

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Fix Timeline**: Depends on severity (critical: 7 days, high: 30 days, medium: 90 days)

## Security Model

### Threat Model

The DEX faces several categories of threats:

1. **Economic Attacks**: MEV, sandwich attacks, oracle manipulation
2. **Smart Contract Bugs**: Reentrancy, integer overflow, logic errors
3. **Governance Attacks**: Malicious upgrades, parameter manipulation
4. **Infrastructure**: RPC failures, relayer compromise

### Trust Assumptions

**Trusted**:

- Ethereum consensus
- OpenZeppelin libraries
- Foundry toolchain

**Minimally Trusted**:

- Relayers (limited to settlement role)
- Governance (protected by timelock)

**Untrusted**:

- Users
- External contracts
- Price oracles (validated via TWAP)

## Security Features

### Access Control

Role-based permissions using OpenZeppelin AccessControl:

| Role               | Permissions       | Holders         |
| ------------------ | ----------------- | --------------- |
| DEFAULT_ADMIN_ROLE | Manage all roles  | Multisig        |
| UPGRADER_ROLE      | Upgrade contracts | Timelock        |
| RELAYER_ROLE       | Settle batches    | Relayer service |
| PAUSER_ROLE        | Emergency pause   | Multisig        |
| FEE_COLLECTOR_ROLE | Collect fees      | Treasury        |

**Principle of Least Privilege**: Each role has minimum necessary permissions.

### Reentrancy Protection

All state-changing functions use `ReentrancyGuard`:

```solidity
contract ConcentratedPool is ReentrancyGuard {
    function swap(...) external nonReentrant returns (...) {
        // Safe from reentrancy
    }
}
```

**Checks-Effects-Interactions Pattern**:

1. Check conditions
2. Update state
3. External calls

### Integer Safety

- Solidity 0.8+ automatic overflow/underflow checks
- Explicit bounds checking for critical values
- Full-precision math libraries (FullMath.sol)

### Oracle Protection

**OracleGuard** prevents price manipulation:

```solidity
function checkPriceDeviation(
    address pool,
    uint160 sqrtPriceX96,
    uint32 twapPeriod,
    uint16 maxDeviationBps
) external view {
    uint160 twapPrice = getTWAP(pool, twapPeriod);
    uint256 deviation = calculateDeviation(sqrtPriceX96, twapPrice);
    require(deviation <= maxDeviationBps, "Price deviation too high");
}
```

### MEV Resistance

**Batch Auctions**:

- Commit-reveal prevents front-running
- Uniform price ensures fairness
- Relayer cannot manipulate clearing price

**AMM**:

- Slippage protection via `amountOutMinimum`
- Deadline checks prevent stale transactions
- Price limit parameters

### Upgrade Safety

**UUPS Pattern**:

- Upgrade logic in implementation
- Authorization required (UPGRADER_ROLE)
- Timelock delay for community review

**Storage Layout Validation**:

```bash
# Check storage layout before upgrade
forge inspect ConcentratedPool storage-layout
```

**Upgrade Checklist**:

- [ ] Storage layout compatible
- [ ] Implementation verified
- [ ] Tested on testnet
- [ ] Community review period
- [ ] Timelock delay observed

## Known Issues

### Resolved

None currently.

### Open

None currently.

## Audit History

### Planned Audits

- [ ] Trail of Bits (Q1 2024)
- [ ] OpenZeppelin (Q2 2024)
- [ ] Consensys Diligence (Q2 2024)

### Audit Reports

Audit reports will be published here after completion.

## Bug Bounty Program

### Scope

**In Scope**:

- All contracts in `contracts/core/`
- All contracts in `contracts/periphery/`
- Relayer service

**Out of Scope**:

- Test contracts
- Known issues
- Issues in dependencies

### Rewards

| Severity | Reward         |
| -------- | -------------- |
| Critical | Up to $100,000 |
| High     | Up to $50,000  |
| Medium   | Up to $10,000  |
| Low      | Up to $1,000   |

### Severity Guidelines

**Critical**:

- Loss of funds
- Unauthorized state changes
- Contract takeover

**High**:

- Temporary freeze of funds
- Griefing attacks
- Significant gas manipulation

**Medium**:

- Incorrect calculations
- Denial of service
- Information disclosure

**Low**:

- Gas optimizations
- Code quality issues
- Best practice violations

## Security Best Practices

### For Integrators

1. **Approve Carefully**: Only approve necessary amounts
2. **Validate Inputs**: Check all user inputs
3. **Handle Errors**: Catch and handle reverts
4. **Monitor Events**: Listen for important events
5. **Use Slippage Protection**: Always set `amountOutMinimum`
6. **Set Deadlines**: Prevent stale transactions

### For Users

1. **Verify Addresses**: Double-check contract addresses
2. **Start Small**: Test with small amounts first
3. **Understand Risks**: Read documentation
4. **Use Hardware Wallets**: For large amounts
5. **Check Approvals**: Revoke unnecessary approvals

### For Operators

1. **Secure Keys**: Use hardware security modules
2. **Monitor Metrics**: Set up alerting
3. **Regular Backups**: Backup relayer database
4. **Update Dependencies**: Keep software current
5. **Incident Response**: Have a plan ready

## Emergency Procedures

### Pause Mechanism

Contracts can be paused in emergency:

```solidity
function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
}

function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
}
```

**When to Pause**:

- Critical bug discovered
- Ongoing attack
- Unexpected behavior

### Incident Response

1. **Detect**: Monitor for anomalies
2. **Assess**: Determine severity
3. **Contain**: Pause if necessary
4. **Investigate**: Analyze root cause
5. **Fix**: Deploy patch
6. **Resume**: Unpause after verification
7. **Post-Mortem**: Document and learn

### Contact Information

**Emergency Contact**: security@hybriddex.io

**Response Team**:

- Security Lead
- Core Developers
- Audit Partners

## Security Tools

### Static Analysis

```bash
# Slither
slither . --exclude-dependencies

# Mythril
myth analyze contracts/core/ConcentratedPool.sol
```

### Testing

```bash
# Fuzz testing
forge test --fuzz-runs 10000

# Invariant testing
forge test --match-path test/*Invariant*

# Fork testing
forge test --fork-url $MAINNET_RPC_URL
```

### Monitoring

- **On-Chain**: Monitor events and state changes
- **Off-Chain**: Track relayer health and performance
- **Alerts**: Set up notifications for anomalies

## Responsible Disclosure

We follow responsible disclosure practices:

1. **Private Reporting**: Report privately to security@hybriddex.io
2. **Acknowledgment**: We acknowledge receipt within 48 hours
3. **Investigation**: We investigate and develop fix
4. **Coordination**: We coordinate disclosure timeline
5. **Public Disclosure**: After fix is deployed
6. **Credit**: We credit reporters (if desired)

## Hall of Fame

Security researchers who have helped secure the protocol:

- (None yet - be the first!)

## Additional Resources

- [Smart Contract Security Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [Solidity Security Considerations](https://docs.soliditylang.org/en/latest/security-considerations.html)
- [DeFi Security Summit](https://defisecuritysummit.org/)

---

Last Updated: 2024-12-13
