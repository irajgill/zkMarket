# 🔮 ZK Cross-Chain Data Marketplace

A production-ready, zero-knowledge powered cross-chain data marketplace featuring Filecoin warm storage, Lighthouse token gating, Self zk identity, Pyth oracles, and 1inch Fusion+ atomic swaps.

## 🌟 Features

- **🔒 Zero-Knowledge Identity**: Privacy-preserving user verification using Self Protocol
- **🏠 Encrypted Storage**: Client-side encryption with Lighthouse access control conditions
- **📊 Dynamic Pricing**: Real-time price feeds from Pyth Network with staleness protection
- **💾 Warm Storage**: Decentralized data storage with Filecoin and Synapse SDK
- **🌊 Cross-Chain Swaps**: HTLC-based atomic swaps compatible with 1inch Fusion+
- **🎲 Verifiable Randomness**: Pyth Entropy for fair lottery systems
- **⚡ UUPS Upgradeable**: Gas-efficient upgradeability with OpenZeppelin

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Frontend      │    │   Off-chain     │    │   Smart         │
│   (Next.js)     │◄──►│   Services      │◄──►│   Contracts     │
│                 │    │   (Node.js)     │    │   (Solidity)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         │                       │                       │
    ┌────▼────┐            ┌─────▼─────┐           ┌─────▼─────┐
    │ Wallet  │            │ External  │           │ Ethereum  │
    │ Connect │            │ Services  │           │ Testnet   │
    └─────────┘            └───────────┘           └───────────┘
                                │
                    ┌───────────┼───────────┐
                    │           │           │
              ┌─────▼─┐   ┌─────▼─┐   ┌─────▼─┐
              │ Pyth  │   │ Self  │   │ 1inch │
              │ Oracle│   │ Proto │   │ Fusion│
              └───────┘   └───────┘   └───────┘
```

## 📦 Smart Contracts

| Contract | Description | Features |
|----------|-------------|----------|
| **DataToken1155** | ERC-1155 token with zk identity | Self integration, EIP-712 permits, Lighthouse gating |
| **PricingOracleAdapter** | Pyth price feed integration | Circuit breakers, subscription management |
| **RNGCoordinator** | Pyth Entropy randomness | Lottery system, prize pools, fair distribution |
| **CrossChainEscrow** | HTLC atomic swaps | 1inch Fusion+ compatible, multi-asset support |
| **DatasetRegistry** | Dataset metadata registry | PDP status tracking, owner management |

## 🚀 Quick Start

### Prerequisites

- Node.js 18+ and npm
- Foundry for smart contract development
- A web3 wallet (MetaMask recommended)

### 1. Clone and Install

```bash
git clone <repository-url>
cd zk-cross-chain-marketplace
npm run install:all
```

### 2. Environment Setup

Create `.env` file:

```env
# Deployment
PRIVATE_KEY=your_private_key_here
RPC_URL=http://localhost:8545

# API Keys
LIGHTHOUSE_API_KEY=your_lighthouse_api_key
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=your_project_id

# Contract Addresses (auto-populated after deployment)
PYTH_CONTRACT_ADDRESS=
PRICING_ORACLE_ADDRESS=
DATA_TOKEN_ADDRESS=
DATASET_REGISTRY_ADDRESS=
RNG_COORDINATOR_ADDRESS=
CROSS_CHAIN_ESCROW_ADDRESS=
```

### 3. Local Development

```bash
# Start local blockchain
npm run start:anvil

# Deploy contracts (new terminal)
npm run deploy:local

# Start off-chain services (new terminal)
npm run start:offchain

# Start frontend (new terminal)
npm run start:frontend
```

Visit `http://localhost:3000` to access the marketplace.

## 🧪 Testing

### Run All Tests

```bash
npm test
```

### Coverage Report

```bash
npm run test:coverage
```

### Gas Report

```bash
npm run test:gas
```

### Specific Test Files

```bash
# Test DataToken contract
forge test --match-contract DataTokenTest

# Test with verbosity
forge test --match-contract DataTokenTest -vvv
```

## 📋 Deployment Guide

### Local Deployment

```bash
# Start Anvil
npm run start:anvil

# Deploy to local network
npm run deploy:local
```

### Testnet Deployment

```bash
# Deploy to Sepolia
npm run deploy:sepolia

# Deploy to Base Sepolia
npm run deploy:base-sepolia
```

### Production Deployment

1. Update environment variables for mainnet
2. Run security audits
3. Deploy with multi-sig wallet
4. Verify contracts on Etherscan

## 🔧 Configuration

### Pyth Price Feeds

Configure price feeds in `offchain/price-relayer.ts`:

```typescript
const config: PriceConfig = {
  priceIds: [
    'e62df6c8b4c85fe1b5a04b3a0e3bd6f7e3c7f6b8c4c85fe1b5a04b3a0e3bd6f7', // BTC/USD
    // Add more price IDs as needed
  ],
  updateInterval: 30000, // 30 seconds
  maxStaleness: 60, // 60 seconds
}
```

### Lighthouse Encryption

Set up access control conditions:

```typescript
const conditions = [{
  id: 1,
  chain: "Base",
  method: "hasAccess",
  standardContractType: "Custom",
  contractAddress: DATA_TOKEN_ADDRESS,
  parameters: [datasetId, ":userAddress"],
  returnValueTest: { comparator: "==", value: "true" }
}]
```

## 📊 Off-Chain Services

### Uploader Service

Handles file uploads to Lighthouse and Synapse:

```bash
cd offchain
npx ts-node uploader.ts <filePath> <datasetName> <description> [--with-access-control]
```

### Price Relayer

Monitors Pyth price feeds and updates on-chain:

```bash
npx ts-node price-relayer.ts
```

### RNG Coordinator

Manages Pyth Entropy requests:

```bash
npx ts-node rng-coordinator.ts
```

### Settlement Broker

Handles 1inch Fusion+ cross-chain settlements:

```bash
npx ts-node settlement-broker.ts
```

## 🔐 Security Features

- **Access Control**: Role-based permissions with OpenZeppelin
- **Upgradeability**: UUPS pattern with timelock governance
- **Circuit Breakers**: Automatic pausing on anomalous conditions
- **Replay Protection**: EIP-712 nonces prevent signature replay
- **ZK Identity**: Self Protocol ensures sybil resistance

## 📈 Integration Examples

### Subscribe to Dataset

```solidity
// Get price quote
uint256 quote = pricingOracle.getQuote(datasetId, duration, updateData);

// Subscribe with payment
pricingOracle.subscribe{value: quote + updateFee}(
    datasetId, 
    duration, 
    updateData
);
```

### Cross-Chain Swap

```solidity
// Create HTLC escrow
bytes32 escrowId = crossChainEscrow.createEscrow(
    encodedIntent,
    signature
);

// Claim with secret on destination chain
crossChainEscrow.claimEscrow(escrowId, secret);
```

### Verify ZK Identity

```solidity
// User generates proof via Self mobile app
bytes memory proof = generateSelfProof();

// Verify on-chain
dataToken.verifySelfProof(proof, userData);
```

## 🐛 Troubleshooting

### Common Issues

1. **Transaction Reverts**: Check gas limits and contract state
2. **Price Staleness**: Ensure price relayer is running
3. **Access Denied**: Verify zk pass is valid and not expired
4. **Upload Fails**: Check Lighthouse API key and file size limits

### Debug Mode

Enable verbose logging:

```bash
export DEBUG=true
npm run start:offchain
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Run the full test suite
5. Submit a pull request

### Code Style

- Follow Solidity style guide
- Use Prettier for TypeScript formatting
- Add comprehensive tests for new features
- Document all public functions

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Self Protocol](https://self.xyz) for zero-knowledge identity
- [Pyth Network](https://pyth.network) for decentralized price feeds
- [Lighthouse](https://lighthouse.storage) for encrypted storage
- [1inch](https://1inch.io) for Fusion+ atomic swaps
- [Filecoin](https://filecoin.io) for decentralized storage
- [OpenZeppelin](https://openzeppelin.com) for secure smart contracts

## 🔗 Links

- [Demo Video](https://example.com/demo)
- [Technical Whitepaper](docs/ARCHITECTURE.md)
- [API Documentation](docs/API.md)
- [Deployment Guide](docs/DEPLOYMENT.md)

---

Built with ❤️ for ETHGlobal New Delhi 2025
