# Polymarket Smart Contract

A production-grade, Polymarket-style prediction market protocol built with Foundry. Deployable on **Arbitrum** and **Abstract**.

## Overview

This protocol implements a fully on-chain prediction market stack:

- **Conditional Token Framework (CTF)** — ERC-1155 outcome tokens for binary markets
- **CTF Exchange** — Hybrid CLOB exchange for binary market trading (COMPLEMENTARY / MINT / MERGE settlement)
- **Neg Risk Adapter** — Multi-outcome categorical market support with NO→YES position conversion
- **Neg Risk CTF Exchange** — Exchange for categorical markets using wrapped collateral
- **Optimistic Oracle** — UMA-style dispute resolution with bonding and liveness windows

## Architecture

```
src/
├── CTF/
│   └── ConditionalTokens.sol        # ERC-1155 outcome token minting/redemption
├── exchange/
│   ├── CTFExchange.sol              # Binary market CLOB exchange
│   └── mixins/
│       ├── OrderStructs.sol         # Order, OrderStatus, Side, SignatureType
│       ├── Auth.sol                 # Admin + operator roles
│       ├── Assets.sol               # Collateral + CTF references
│       ├── Fees.sol                 # Fee constants and calculation
│       ├── NonceManager.sol         # Per-user nonce-based order cancellation
│       ├── Pausable.sol             # Emergency circuit breaker
│       ├── Registry.sol             # Token pair registry
│       ├── Signing.sol              # EIP-712 + multi-sig-type verification
│       └── Trading.sol              # Fill / match order logic
├── neg-risk/
│   ├── WrappedCollateral.sol        # 1:1 USDC wrapper for CTF internals
│   ├── Vault.sol                    # Protocol fee accumulator
│   ├── NegRiskAdapter.sol           # NO-to-YES position conversion engine
│   ├── NegRiskOperator.sol          # Admin and oracle governance layer
│   ├── NegRiskCTFExchange.sol       # Exchange for categorical markets
│   └── NegRiskFeeModule.sol         # Per-token fee configuration
├── oracle/
│   └── OptimisticOracle.sol         # Optimistic oracle with dispute mechanism
└── interfaces/
    ├── IConditionalTokens.sol
    └── ICTFExchange.sol
```

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (optional, for additional tooling)

## Installation

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repository
git clone <repo-url>
cd smart-contract

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts --no-git
```

## Configuration

Copy the example environment file and populate it:

```bash
cp .env.example .env
```

| Variable | Description |
|---|---|
| `PRIVATE_KEY` | Deployer private key |
| `ARBITRUM_RPC_URL` | Arbitrum RPC endpoint |
| `ABSTRACT_RPC_URL` | Abstract RPC endpoint |
| `ARBISCAN_API_KEY` | Arbiscan API key for contract verification |
| `ABSTRACT_API_KEY` | Abstract explorer API key |
| `COLLATERAL_ADDRESS` | USDC address on the target chain |
| `FEE_RECEIVER` | Address to receive protocol fees |
| `ORACLE_ADDRESS` | Off-chain oracle EOA or contract |

**USDC addresses:**

| Chain | Address |
|---|---|
| Arbitrum One | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Abstract | See Abstract bridge documentation |

## Usage

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Verbose output with traces
forge test -vvv

# Run a specific test file
forge test --match-path test/unit/CTFExchange.t.sol

# Run a specific test function
forge test --match-test test_fillOrder_sell_transfersTokens

# Coverage report
forge coverage
```

### Gas Snapshots

```bash
forge snapshot
```

### Format

```bash
forge fmt
```

### Local Node

```bash
anvil
```

## Deployment

### Arbitrum

```bash
forge script script/deploy/Deploy.s.sol \
  --rpc-url arbitrum \
  --broadcast \
  --verify
```

### Abstract

```bash
forge script script/deploy/Deploy.s.sol \
  --rpc-url abstract \
  --broadcast \
  --verify
```

The deployment script prints all contract addresses on completion. Save these — they are required to register token pairs, configure operators, and integrate with the oracle.

## Post-Deployment Setup

After deployment, the following steps are required before the protocol is operational:

1. **Register token pairs** — Call `CTFExchange.registerToken(token0, token1, conditionId)` for each binary market.
2. **Add operators** — Call `CTFExchange.addOperator(address)` to authorize off-chain matching services.
3. **Prepare markets** — Call `NegRiskAdapter.prepareMarket(feeBips, data)` for categorical markets.
4. **Set oracle** — Call `NegRiskOperator.setOracle(address)` (one-time).
5. **Configure fees** — Call `NegRiskFeeModule.setDefaultFeeRate(bps)` as needed.

## Contract Interactions

### Binary Market Flow

```
User → splitPosition() → ConditionalTokens
     ← YES + NO ERC-1155 tokens

Operator → matchOrders() → CTFExchange
         ← atomic settlement on-chain

User → redeemPositions() → ConditionalTokens
     ← USDC payout after resolution
```

### Categorical Market Flow

```
User → splitPosition() → NegRiskAdapter → ConditionalTokens
     ← YES + NO tokens (wrapped collateral)

User → convertPositions() → NegRiskAdapter
     ← YES tokens for each outcome in batch

Oracle → reportOutcome() → NegRiskAdapter → ConditionalTokens
       ← condition resolved

User → redeemPositions() → NegRiskAdapter → ConditionalTokens
     ← USDC payout
```

### Oracle Flow

```
Asserter → makeAssertion()   → OptimisticOracle  (posts bond)
Disputer → disputeAssertion() → OptimisticOracle  (posts equal bond)

[Undisputed after liveness]
Anyone   → settleAssertion()  → OptimisticOracle → ConditionalTokens.reportPayouts()
         ← bond returned to asserter

[Disputed]
Admin    → arbitrate()        → OptimisticOracle → ConditionalTokens.reportPayouts()
         ← bonds awarded to winner
```

## Security

- All exchange entry points are protected by `ReentrancyGuard`
- Orders use EIP-712 typed data signatures
- Supports EOA, Proxy Wallet, Gnosis Safe, and ERC-1271 signature types
- Per-user nonce system for off-chain order cancellation
- Emergency `pauseTrading()` on all exchanges
- Admin / operator role separation — operators can settle trades, only admins can change system config
- Maximum fee rate capped at 10% (1000 bps)
- Emergency resolution delay of 48 hours after flagging a disputed question

> **This protocol has not been audited. Do not deploy with real funds until a full security audit has been completed.**

## License

MIT

## Contact

For questions or collaboration, reach out via [Telegram](https://t.me/haredoggy).
