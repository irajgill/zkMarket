import {EvmPriceServiceConnection} from '@pythnetwork/pyth-evm-js';
import * as dotenv from 'dotenv';
import {ethers} from 'ethers';
import WebSocket from 'ws';

dotenv.config();

interface PriceConfig {
  privateKey: string;
  rpcUrl: string;
  pythContractAddress: string;
  pricingOracleAddress: string;
  hermesUrl: string;
  priceIds: string[];
  updateInterval: number;
  maxStaleness: number;
}

function extractErr(e: unknown): { code?: string; message?: string } {
  if (typeof e === 'object' && e !== null) {
    const anyE = e as any;
    return { code: anyE?.code, message: anyE?.message };
  }
  return {};
}

// Normalize price ID to bytes32 format for contract calls
function toBytes32(id: string): string {
  const hex = id.startsWith('0x') ? id.slice(2) : id;
  return '0x' + hex.padStart(64, '0');
}

// Ensure 0x prefix for Hermes calls
function toHermesId(id: string): string {
  return id.startsWith('0x') ? id : '0x' + id;
}

class PythPriceRelayer {
  private config: PriceConfig;
  private provider: ethers.Provider;
  private wallet: ethers.Wallet;
  private pythConnection: EvmPriceServiceConnection;
  private pythContract!: ethers.Contract;
  private oracleContract!: ethers.Contract;
  private ws: WebSocket | null = null;
  private isRunning = false;

  constructor(config: PriceConfig) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);
    this.pythConnection = new EvmPriceServiceConnection(config.hermesUrl);

    console.log('🔗 Price relayer initialized for wallet:', this.wallet.address);
    console.log('📊 Monitoring price IDs:', config.priceIds);
  }

  async initialize() {
    try {
      const pythABI = [
        'function updatePriceFeeds(bytes[] calldata updateData) external payable',
        'function getUpdateFee(bytes[] calldata updateData) external view returns (uint256)',
        'function getPrice(bytes32 id) external view returns (tuple(int64 price, uint64 conf, int32 expo, uint256 publishTime))',
        'function getPriceUnsafe(bytes32 id) external view returns (tuple(int64 price, uint64 conf, int32 expo, uint256 publishTime))',
        // Add mock-specific functions if available
        'function setPrice(bytes32 id, int64 price, int32 expo) external',
      ];

      this.pythContract = new ethers.Contract(
        this.config.pythContractAddress,
        pythABI,
        this.wallet
      );

      const oracleABI = [
        'function getCurrentPrice(bytes[] calldata updateData) external payable returns (int64 price, int32 expo, uint64 publishTime)',
        'function maxStaleness() external view returns (uint32)',
        'event PriceUpdated(bytes32 indexed priceId, int64 price, uint64 publishTime)',
        'event PriceStale(uint64 publishTime, uint32 maxStaleness)',
      ];

      this.oracleContract = new ethers.Contract(
        this.config.pricingOracleAddress,
        oracleABI,
        this.wallet
      );

      console.log('✅ Contracts initialized');
      console.log('   📊 Pyth Contract:', this.config.pythContractAddress);
      console.log('   🏪 Oracle Contract:', this.config.pricingOracleAddress);

      // Try to seed mock contract with initial price data
      await this.seedMockPriceData();
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Initialization failed:', e.message ?? error);
      throw error;
    }
  }

  // Seed MockPyth with initial price data
  private async seedMockPriceData() {
    try {
      for (const priceId of this.config.priceIds) {
        const bytes32Id = toBytes32(priceId);
        // Set initial BTC price: ~$109,000 with expo -8
        await this.pythContract.setPrice(bytes32Id, 10900000000000n, -8);
        console.log(`✅ Seeded mock price for ${priceId.slice(0, 8)}...`);
      }
    } catch (error) {
      console.log('⚠️ Could not seed mock prices (contract may not support setPrice)');
    }
  }

  async start() {
    this.isRunning = true;
    console.log('🚀 Starting Pyth price relayer...');

    this.startPeriodicUpdates();
    this.startWebSocketConnection();
    this.startStalenessMonitor();

    console.log('✅ Price relayer started');
  }

  async stop() {
    this.isRunning = false;
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    console.log('🛑 Price relayer stopped');
  }

  private startPeriodicUpdates() {
    const updatePrices = async () => {
      if (!this.isRunning) return;

      try {
        await this.updatePrices();
      } catch (error) {
        const e = extractErr(error);
        console.error('❌ Periodic update failed:', e.message ?? error);
      }

      if (this.isRunning) {
        setTimeout(updatePrices, this.config.updateInterval);
      }
    };

    updatePrices();
  }

  private startWebSocketConnection() {
    const connectWebSocket = () => {
      if (!this.isRunning) return;

      try {
        const wsUrl = this.config.hermesUrl.replace('https://', 'wss://').replace('http://', 'ws://') + '/ws';
        this.ws = new WebSocket(wsUrl);

        this.ws.on('open', () => {
          console.log('🌐 WebSocket connected to Hermes');
          // Send 0x-prefixed IDs to Hermes
          const hermesIds = this.config.priceIds.map(toHermesId);
          this.ws?.send(JSON.stringify({
            type: 'subscribe',
            ids: hermesIds,
          }));
        });

        this.ws.on('message', async (data) => {
          try {
            const message = JSON.parse(data.toString());
            
            // Handle different message formats from Hermes
            if (message.type === 'price_update') {
              // Handle both message.data and message.price_feed formats
              const priceData = message.data || message.price_feed;
              if (priceData) {
                console.log('📈 Real-time price update received');
                await this.handleRealtimeUpdate(priceData);
              } else {
                console.warn('⚠️ Price update message missing data:', message);
              }
            } else if (message.type === 'response') {
              // Hermes subscription confirmation
              console.log('📡 Hermes subscription confirmed:', message.status);
            } else {
              console.warn('⚠️ Unexpected WebSocket message format:', message);
            }
          } catch (error) {
            const e = extractErr(error);
            console.error('❌ WebSocket message error:', e.message ?? error);
          }
        });

        this.ws.on('close', () => {
          console.log('📡 WebSocket disconnected');
          if (this.isRunning) {
            setTimeout(connectWebSocket, 5000);
          }
        });

        this.ws.on('error', (error) => {
          console.error('❌ WebSocket error:', error);
        });
      } catch (error) {
        const e = extractErr(error);
        console.error('❌ WebSocket connection failed:', e.message ?? error);
        if (this.isRunning) {
          setTimeout(connectWebSocket, 10000);
        }
      }
    };

    connectWebSocket();
  }

  private startStalenessMonitor() {
    const checkStaleness = async () => {
      if (!this.isRunning) return;

      try {
        await this.checkPriceStaleness();
      } catch (error) {
        const e = extractErr(error);
        console.error('❌ Staleness check failed:', e.message ?? error);
      }

      if (this.isRunning) {
        setTimeout(checkStaleness, 60_000);
      }
    };

    checkStaleness();
  }

  private async updatePrices() {
    try {
      console.log('🔄 Fetching price updates from Hermes...');
      const hermesIds = this.config.priceIds.map(toHermesId);
      const updateData = await this.pythConnection.getPriceFeedsUpdateData(hermesIds);

      if (!updateData || updateData.length === 0) {
        console.log('⚠️ No price update data available');
        return;
      }

      const updateFee = await this.pythContract.getUpdateFee(updateData);
      console.log('💰 Update fee:', ethers.formatEther(updateFee), 'ETH');

      const balance = await this.provider.getBalance(this.wallet.address);
      console.log('💰 Wallet balance:', ethers.formatEther(balance), 'ETH');
      
      if (balance < updateFee * 2n) { // Need fee for both Pyth and Oracle updates
        console.error('❌ Insufficient balance for price update');
        return;
      }

      console.log('📤 Submitting price update transaction...');
      const tx = await this.pythContract.updatePriceFeeds(updateData, {
        value: updateFee,
        gasLimit: 500_000,
      });

      console.log('⏳ Transaction hash:', tx.hash);
      const receipt = await tx.wait();

      if (receipt.status === 1) {
        console.log('✅ Price update successful');
        await this.logCurrentPrices();
        
        // Schedule oracle update with better error handling
        console.log('⏰ Scheduling oracle update in 2 seconds...');
        setTimeout(async () => {
          try {
            await this.updateOracleWithFreshData();
          } catch (error) {
            const e = extractErr(error);
            console.error('❌ Oracle update scheduling failed:', e.message ?? error);
          }
        }, 2000);
      } else {
        console.error('❌ Price update transaction failed');
      }
    } catch (error) {
      const { code, message } = extractErr(error);
      console.error('❌ Price update failed:', message ?? error);

      if (code === 'INSUFFICIENT_FUNDS') {
        console.error('💸 Insufficient funds for transaction');
      } else if (code === 'REPLACEMENT_UNDERPRICED') {
        console.log('⚠️ Transaction underpriced, will retry');
      }
    }
  }

  // New method to update oracle with fresh data
  private async updateOracleWithFreshData() {
    try {
      console.log('🔄 Fetching fresh price data for oracle update...');
      const hermesIds = this.config.priceIds.map(toHermesId);
      const freshUpdateData = await this.pythConnection.getPriceFeedsUpdateData(hermesIds);
      
      if (!freshUpdateData || freshUpdateData.length === 0) {
        console.log('⚠️ No fresh update data available for oracle');
        return;
      }

      await this.updateOracle(freshUpdateData);
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Failed to get fresh data for oracle:', e.message ?? error);
    }
  }

  private async handleRealtimeUpdate(priceData: any) {
    console.log('📊 Real-time price data received:', {
      id: priceData.id?.slice(0, 10) + '...',
      price: priceData.price?.price || priceData.price, // Handle both formats
      expo: priceData.price?.expo || priceData.expo,
      publishTime: priceData.price?.publish_time || priceData.publishTime
    });
    
    const shouldUpdate = await this.shouldUpdateOnChain(priceData);
    if (shouldUpdate) {
      console.log('🚨 Significant price change detected, updating on-chain');
      await this.updatePrices();
    }
  }

  // Safe price reader that handles mock contract limitations
  private async readPrice(priceId: string) {
    const bytes32Id = toBytes32(priceId);
    
    try {
      // Try getPriceUnsafe first (works on real Pyth)
      return await this.pythContract.getPriceUnsafe(bytes32Id);
    } catch (error) {
      try {
        // Fallback to getPrice (works on most implementations)
        return await this.pythContract.getPrice(bytes32Id);
      } catch (fallbackError) {
        // Return zero data if both fail
        return {
          price: 0n,
          conf: 0n,
          expo: -8,
          publishTime: 0n
        };
      }
    }
  }

  private async shouldUpdateOnChain(priceData: any): Promise<boolean> {
    try {
      // Handle both nested and flat price data formats
      const newPrice = Number(priceData.price?.price || priceData.price || 0);
      const publishTime = Number(priceData.price?.publish_time || priceData.publishTime || 0);
      
      if (newPrice === 0 || publishTime === 0) {
        return false; // Invalid price data
      }

      // Check staleness based on real-time data publish time
      const currentTime = Math.floor(Date.now() / 1000);
      const isStale = currentTime - publishTime > this.config.maxStaleness;
      
      // For now, update based on staleness. You can add price change logic later
      return isStale;
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Error checking price significance:', e.message ?? error);
      return false;
    }
  }

  // Updated oracle update method with better error handling and debugging
  private async updateOracle(updateData: any[]) {
    try {
      console.log('🔄 Updating oracle with fresh price data...');
      
      // First try: Oracle might read directly from already-updated Pyth contract
      try {
        console.log('📊 Trying oracle update without updateData (reading from Pyth)...');
        const tx = await this.oracleContract.getCurrentPrice([], {
          gasLimit: 200_000,
        });
        
        console.log('⏳ Oracle tx hash (no data):', tx.hash);
        const receipt = await tx.wait();
        
        if (receipt.status === 1) {
          console.log('✅ Oracle updated successfully (reading from Pyth)');
          return;
        } else {
          console.log('❌ Oracle update failed (no data), trying with updateData...');
        }
      } catch (error) {
        const e = extractErr(error);
        console.log('📊 Oracle requires updateData, proceeding with fresh data...');
        console.log('   Error was:', e.message);
      }
      
      // Second try: Use fresh updateData
      console.log('💰 Calculating update fee for oracle...');
      const updateFee = await this.pythContract.getUpdateFee(updateData);
      console.log('💰 Oracle update fee:', ethers.formatEther(updateFee), 'ETH');
      
      const tx = await this.oracleContract.getCurrentPrice(updateData, {
        value: updateFee,
        gasLimit: 300_000,
      });
      
      console.log('⏳ Oracle tx hash (with data):', tx.hash);
      const receipt = await tx.wait();

      if (receipt.status === 1) {
        console.log('✅ Oracle updated successfully with fresh data');
      } else {
        console.error('❌ Oracle update tx failed with fresh data');
      }
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Oracle update failed:', e.message ?? error);
      
      // More detailed error analysis
      if (e.message?.includes('execution reverted')) {
        console.log('💡 Hint: Oracle contract might expect different parameters');
        console.log('💡 Try checking the PricingOracleAdapter contract implementation');
      } else if (e.message?.includes('insufficient funds')) {
        console.log('💡 Hint: Need more ETH for oracle update fee');
      } else if (e.message?.includes('nonce')) {
        console.log('💡 Hint: Nonce issue, might resolve on retry');
      }
    }
  }

  private async logCurrentPrices() {
    try {
      console.log('\n📊 Current Prices:');
      console.log('================');

      for (const priceId of this.config.priceIds) {
        const price = await this.readPrice(priceId);

        const px = Number(price.price);
        const expo = Number(price.expo);
        const value = px * Math.pow(10, expo);
        const conf = Number(price.conf) * Math.pow(10, expo);

        console.log(`Price ID: ${priceId.slice(0, 8)}...`);
        console.log(`  Price: $${value.toFixed(2)}`);
        console.log(`  Confidence: ±$${conf.toFixed(2)}`);
        console.log(`  Published: ${new Date(Number(price.publishTime) * 1000).toISOString()}`);
        console.log('');
      }
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Error logging prices:', e.message ?? error);
    }
  }

  private async checkPriceStaleness() {
    try {
      const maxStaleness = await this.oracleContract.maxStaleness();
      const currentTime = Math.floor(Date.now() / 1000);

      for (const priceId of this.config.priceIds) {
        const price = await this.readPrice(priceId);
        const publishTime = Number(price.publishTime);
        
        if (publishTime === 0) {
          console.warn(`⚠️ No price data found for ${priceId.slice(0, 8)}...`);
          continue;
        }
        
        const age = currentTime - publishTime;

        if (age > Number(maxStaleness)) {
          console.warn(`⚠️ Stale price detected for ${priceId.slice(0, 8)}... (${age}s old)`);
          await this.updatePrices();
          break;
        }
      }
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Staleness check failed:', e.message ?? error);
    }
  }

  async getHealthStatus() {
    try {
      const status = {
        isRunning: this.isRunning,
        walletAddress: this.wallet.address,
        walletBalance: ethers.formatEther(await this.provider.getBalance(this.wallet.address)),
        wsConnected: this.ws?.readyState === WebSocket.OPEN,
        priceIds: this.config.priceIds,
        lastUpdate: new Date().toISOString(),
      };

      return status;
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Health check failed:', e.message ?? error);
      return { error: e.message ?? String(error) };
    }
  }
}

// CLI
async function main() {
  const config: PriceConfig = {
    privateKey: process.env.PRIVATE_KEY!,
    rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
    pythContractAddress: process.env.PYTH_CONTRACT_ADDRESS!,
    pricingOracleAddress: process.env.PRICING_ORACLE_ADDRESS!,
    hermesUrl: process.env.HERMES_URL || 'https://hermes.pyth.network',
    priceIds: process.env.BTC_USD_PRICE_ID?.split(',').map((s) => s.trim()).filter(Boolean) || [
      // Use the REAL BTC/USD price feed ID from Pyth
      'e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43',
    ],
    updateInterval: parseInt(process.env.UPDATE_INTERVAL || '30000', 10),
    maxStaleness: parseInt(process.env.MAX_STALENESS || '60', 10),
  };

  const relayer = new PythPriceRelayer(config);

  try {
    await relayer.initialize();
    await relayer.start();

    process.on('SIGINT', async () => {
      console.log('\n👋 Received SIGINT, shutting down gracefully...');
      await relayer.stop();
      process.exit(0);
    });

    console.log('✅ Price relayer running. Press Ctrl+C to stop.');
  } catch (error) {
    const e = extractErr(error);
    console.error('💥 Relayer failed:', e.message ?? error);
    process.exit(1);
  }
}

if (require.main === module) {
  main().catch((e) => {
    const err = extractErr(e);
    console.error('💥 Top-level error:', err.message ?? e);
    process.exit(1);
  });
}

export {PriceConfig, PythPriceRelayer};
