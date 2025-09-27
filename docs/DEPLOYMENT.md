# 🚀 Deployment Guide

## Prerequisites

- Node.js 18+ and npm
- Foundry installed
- Git
- A funded wallet for deployment
- API keys for external services

## Environment Setup

### 1. Clone Repository
```bash
git clone <repository-url>
cd zk-cross-chain-marketplace
npm run install:all
```

### 2. Environment Variables

Create `.env` file in the root directory:

```env
# Deployment Keys
PRIVATE_KEY=0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
DEPLOYER_ADDRESS=0x742d35Cc6634C0532925a3b8D1d2c6af8F6E4530

# RPC URLs
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY

# Verification Keys
ETHERSCAN_API_KEY=ABC123DEF456GHI789JKL012MNO345PQR678STU
BASESCAN_API_KEY=ABC123DEF456GHI789JKL012MNO345PQR678STU
ARBISCAN_API_KEY=ABC123DEF456GHI789JKL012MNO345PQR678STU

# External Service APIs
LIGHTHOUSE_API_KEY=your_lighthouse_api_key_here
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=your_walletconnect_project_id

# Production Contract Addresses (for mainnet deployment)
PYTH_CONTRACT_ADDRESS=0xff1a0f4744e8582DF1aE09D5611b887B6a12925C
ENTROPY_CONTRACT_ADDRESS=0x7698E925FfC29655576D0b361D75Af579e20AdAc
SELF_HUB_CONTRACT_ADDRESS=0x...

# Configuration
BTC_USD_PRICE_ID=0xe62df6c8b4c85fe1b5a04b3a0e3bd6f7e3c7f6b8c4c85fe1b5a04b3a0e3bd6f7
MAX_STALENESS=60
DATA_TOKEN_URI=https://api.zk-marketplace.com/metadata/{id}
```

## Local Development Deployment

### 1. Start Local Blockchain
```bash
npm run start:anvil
```

### 2. Deploy Contracts
```bash
npm run deploy:local
```

This will deploy all contracts with mock external dependencies.

### 3. Seed Demo Data
```bash
npm run seed
```

### 4. Start Services
```bash
# Start all off-chain services
npm run start:offchain

# Start frontend (new terminal)
npm run start:frontend
```

## Testnet Deployment

### Base Sepolia Deployment

```bash
# Deploy to Base Sepolia
npm run deploy:base-sepolia

# Verify contracts
forge verify-contract --chain base-sepolia <CONTRACT_ADDRESS> <CONTRACT_NAME>
```

### Sepolia Deployment

```bash
# Deploy to Sepolia
npm run deploy:sepolia

# Verify contracts
forge verify-contract --chain sepolia <CONTRACT_ADDRESS> <CONTRACT_NAME>
```

## Production Deployment

### Pre-Deployment Checklist

- [ ] Security audit completed
- [ ] All tests passing with 100% coverage
- [ ] Multi-sig wallet prepared for ownership
- [ ] Production RPC endpoints configured
- [ ] Monitoring and alerting set up
- [ ] Backup and recovery procedures tested

### 1. Deploy to Mainnet

```bash
# Deploy with production configuration
NETWORK=mainnet forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify --slow
```

### 2. Transfer Ownership

```bash
# Transfer to multi-sig or DAO
forge script script/TransferOwnership.s.sol --rpc-url $MAINNET_RPC_URL --broadcast
```

### 3. Initialize Services

```bash
# Set up price feeds
npx ts-node offchain/price-relayer.ts --network mainnet --setup

# Configure oracle parameters
npx ts-node scripts/configure-oracle.ts --network mainnet
```

## Multi-Chain Deployment

### Deploy to Multiple Networks

```bash
# Deploy to all target networks
npm run deploy:multi-chain
```

This script deploys to:
- Ethereum Mainnet
- Base
- Arbitrum
- Polygon (optional)

### Cross-Chain Configuration

Update the CrossChainEscrow with supported chain IDs:

```solidity
mapping(uint256 => bool) public supportedChains;

function addSupportedChain(uint256 chainId) external onlyOwner {
    supportedChains[chainId] = true;
}
```

## Service Deployment

### Off-Chain Services

Deploy to cloud infrastructure:

```bash
# Deploy price relayer
docker build -t zk-marketplace/price-relayer ./offchain
docker run -d --env-file .env zk-marketplace/price-relayer

# Deploy uploader service
docker build -t zk-marketplace/uploader ./offchain
docker run -d --env-file .env zk-marketplace/uploader
```

### Frontend Deployment

Deploy to Vercel or similar platform:

```bash
cd frontend
npm run build
npm run start
```

## Monitoring Setup

### 1. Contract Monitoring

Set up monitoring for:
- Price update frequency
- Circuit breaker activations
- Failed transactions
- Gas usage patterns

### 2. Service Health Checks

Monitor:
- RPC endpoint availability
- External API response times
- Service restart counts
- Error rates

### 3. User Metrics

Track:
- Daily active users
- Subscription rates
- Dataset upload frequency
- Cross-chain swap volume

## Security Considerations

### 1. Access Control

- Use multi-sig wallets for admin functions
- Implement timelock for critical parameter changes
- Regular security audits
- Bug bounty program

### 2. Circuit Breakers

Configure automatic pausing for:
- Price anomalies (>50% deviation)
- Oracle failures (>60 seconds stale)
- Unusual transaction patterns
- External service outages

### 3. Upgrade Safety

- Test all upgrades on testnet first
- Use transparent proxy patterns
- Implement governance delays
- Maintain emergency pause functionality

## Troubleshooting

### Common Deployment Issues

1. **Gas Estimation Failures**
   ```bash
   # Use higher gas limit
   forge script --gas-limit 10000000
   ```

2. **RPC Rate Limiting**
   ```bash
   # Add delays between transactions
   forge script --slow --delay 10
   ```

3. **Verification Failures**
   ```bash
   # Manual verification
   forge verify-contract --constructor-args $(cast abi-encode "constructor(address,bytes32,uint32,address)" $PYTH $PRICE_ID $STALENESS $OWNER) $CONTRACT_ADDRESS PricingOracleAdapter
   ```

### Rollback Procedures

1. **Contract Issues**
   - Pause affected contracts
   - Investigate root cause
   - Deploy fixed version
   - Upgrade through governance

2. **Service Issues**
   - Switch to backup services
   - Rollback to previous version
   - Monitor for stability
   - Gradually restore traffic

## Post-Deployment Tasks

### 1. Verify Deployment

```bash
# Run integration tests
npm run test:integration

# Check contract verification
npm run verify:all
```

### 2. Configure Services

```bash
# Set up monitoring
npm run setup:monitoring

# Configure alerts
npm run setup:alerts
```

### 3. Documentation Updates

- Update contract addresses in documentation
- Publish API documentation
- Create user guides
- Announce deployment

## Maintenance

### Regular Tasks

- Monitor contract performance
- Update price feed configurations
- Review security alerts
- Backup deployment artifacts

### Upgrade Process

1. Deploy new implementation
2. Test on staging environment
3. Submit governance proposal
4. Execute upgrade after timelock
5. Monitor post-upgrade metrics

This deployment guide ensures a secure and reliable deployment of the ZK Cross-Chain Data Marketplace across all target environments.
