# 📚 API Documentation

## Smart Contract APIs

### DataToken1155

#### Functions

##### `initialize(address hubV2, string memory scopeSeed, string memory uri_)`
Initializes the upgradeable token contract.

**Parameters:**
- `hubV2`: Address of the Self Protocol Hub V2 contract
- `scopeSeed`: Unique scope identifier for Self verification
- `uri_`: Base URI for token metadata

##### `mint(bytes32 datasetId, address to, uint256 id, uint256 amount, bytes memory data)`
Mints dataset access tokens to a user.

**Requirements:**
- Caller must have CURATOR_ROLE
- Recipient must have valid zk pass
- Recipient must not be denylisted

##### `hasAccess(bytes32 datasetId, address user)`
Checks if a user has access to a dataset (used by Lighthouse).

**Returns:** `bool` - True if user has valid access

### PricingOracleAdapter

#### Functions

##### `getQuote(bytes32 datasetId, uint32 duration, bytes[] calldata updateData)`
Gets a price quote for dataset subscription.

**Parameters:**
- `datasetId`: ID of the dataset
- `duration`: Subscription duration in seconds
- `updateData`: Pyth price update data

**Returns:** `uint256` - Price quote in wei

##### `subscribe(bytes32 datasetId, uint32 durationSeconds, bytes[] calldata updateData)`
Subscribes to a dataset with payment.

**Requirements:**
- Contract must not be paused
- Sufficient payment must be provided
- Price data must be fresh

## Off-Chain Service APIs

### Uploader Service

#### Usage
```bash
npx ts-node uploader.ts <filePath> <datasetName> <description> [--with-access-control]
```

#### Example
```bash
npx ts-node uploader.ts ./data.json "Weather Data" "Global weather measurements" --with-access-control
```

### Price Relayer

#### Configuration
Set environment variables:
```env
PYTH_CONTRACT_ADDRESS=0x...
PRICING_ORACLE_ADDRESS=0x...
HERMES_URL=https://hermes.pyth.network
PRICE_IDS=e62df6c8b4c85fe1b5a04b3a0e3bd6f7e3c7f6b8c4c85fe1b5a04b3a0e3bd6f7
UPDATE_INTERVAL=30000
MAX_STALENESS=60
```

### Frontend Components

#### DatasetBrowser
Displays available datasets with subscription management.

#### PriceOracle
Shows real-time price feeds and circuit breaker status.

#### RNGLottery
Lottery interface for premium dataset access.

## Integration Examples

### Subscribe to Dataset
```typescript
import { ethers } from 'ethers'

const pricingOracle = new ethers.Contract(address, abi, signer)

// Get price quote
const quote = await pricingOracle.getQuote(datasetId, duration, updateData)

// Subscribe with payment
const tx = await pricingOracle.subscribe(datasetId, duration, updateData, {
  value: quote + updateFee
})
```

### Upload with Lighthouse
```typescript
import lighthouse from '@lighthouse-web3/sdk'

// Upload and encrypt
const response = await lighthouse.uploadBuffer(
  fileBuffer,
  apiKey,
  fileName
)

// Apply access control
await lighthouse.applyAccessCondition(
  publicKey,
  response.data.Hash,
  signedMessage,
  accessConditions,
  "([1])"
)
```

### Verify Self Identity
```typescript
// Generate proof via Self mobile app
const proof = await generateSelfProof()

// Verify on-chain
const tx = await dataToken.verifySelfProof(proof, userData)
```

## Error Codes

### Contract Errors

| Error | Description |
|-------|-------------|
| `DataToken1155: user denylisted` | User is on the denylist |
| `DataToken1155: zk pass expired` | User's zk pass has expired |
| `PricingOracleAdapter: insufficient payment` | Payment amount too low |
| `StalePriceData` | Price data is too old |
| `PriceOutOfRange` | Price outside acceptable range |

### HTTP Status Codes

| Code | Description |
|------|-------------|
| 200 | Success |
| 400 | Bad Request |
| 401 | Unauthorized |
| 429 | Rate Limited |
| 500 | Internal Server Error |

## Rate Limits

- Price updates: 1 per 10 seconds per user
- RNG requests: 1 per 5 minutes per user
- File uploads: 10 per hour per user

## WebSocket Events

### Price Relayer
```typescript
ws.on('price_update', (data) => {
  console.log('New price:', data.price)
})
```

### RNG Coordinator
```typescript
contract.on('LotteryFulfilled', (datasetId, user, sequenceNumber, randomNumber) => {
  console.log('Lottery result:', { datasetId, user, randomNumber })
})
```

This API documentation provides the essential interfaces for integrating with the ZK Cross-Chain Data Marketplace.
