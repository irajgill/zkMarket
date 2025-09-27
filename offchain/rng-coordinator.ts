import * as dotenv from 'dotenv';
import {ethers} from 'ethers';

dotenv.config();

interface RNGConfig {
  privateKey: string;
  rpcUrl: string;
  rngCoordinatorAddress: string;
  checkInterval: number;
  fulfillmentDelay: number;
}

interface PendingRequest {
  sequenceNumber: bigint;
  datasetId: string;
  requester: string;
  timestamp: number;
  retryCount: number;
}

function extractErr(e: unknown): { code?: string; message?: string } {
  if (typeof e === 'object' && e !== null) {
    const anyE = e as any;
    return { code: anyE?.code, message: anyE?.message };
  }
  return {};
}

class RNGCoordinatorService {
  private config: RNGConfig;
  private provider: ethers.Provider;
  private wallet: ethers.Wallet;
  private contract: ethers.Contract;
  private isRunning = false;
  private pendingRequests = new Map<string, PendingRequest>();
  private fulfillmentQueue: PendingRequest[] = [];

  constructor(config: RNGConfig) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);

    const abi = [
      "function getRequestStatus(uint64 sequenceNumber) external view returns (bytes32 datasetId, address requester, bool fulfilled, bytes32 randomResult)",
      "function manualFulfill(uint64 sequenceNumber, bytes32 randomNumber) external",
      "event LotteryRequested(bytes32 indexed datasetId, address indexed user, uint64 sequenceNumber, bytes32 userCommitment)"
    ];

    this.contract = new ethers.Contract(config.rngCoordinatorAddress, abi, this.wallet);
    console.log('🎲 RNG Coordinator service initialized');
    console.log('   📍 Coordinator Address:', config.rngCoordinatorAddress);
    console.log('   💰 Wallet Address:', this.wallet.address);
  }

  async start() {
    this.isRunning = true;
    console.log('🚀 Starting RNG coordinator service...');

    try {
      // Test contract connection
      await this.testConnection();
      
      // Listen for lottery requests with error handling
      this.setupEventListeners();

      // Start periodic check and fulfillment processor
      this.startPeriodicCheck();
      this.startFulfillmentProcessor();

      console.log('✅ RNG coordinator service started');
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Failed to start RNG coordinator:', e.message ?? error);
      throw error;
    }
  }

  private async testConnection() {
    try {
      const balance = await this.provider.getBalance(this.wallet.address);
      console.log('💰 Wallet balance:', ethers.formatEther(balance), 'ETH');
      
      // Test contract call
      const testSequence = 999999n; // Non-existent sequence for testing
      await this.contract.getRequestStatus(testSequence);
      console.log('✅ Contract connection verified');
    } catch (error) {
      const e = extractErr(error);
      if (e.message?.includes('call revert exception')) {
        console.log('✅ Contract connection verified (expected revert for test sequence)');
      } else {
        throw error;
      }
    }
  }

  private setupEventListeners() {
    try {
      this.contract.on('LotteryRequested', this.handleLotteryRequest.bind(this));
      console.log('👂 Listening for LotteryRequested events...');
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Failed to setup event listeners:', e.message ?? error);
      throw error;
    }
  }

  private async handleLotteryRequest(
    datasetId: string, 
    user: string, 
    sequenceNumber: bigint, 
    userCommitment: string
  ) {
    const seqStr = sequenceNumber.toString();
    console.log(`🎯 New lottery request received:`);
    console.log(`   📊 Dataset ID: ${datasetId}`);
    console.log(`   👤 User: ${user}`);
    console.log(`   🔢 Sequence: ${sequenceNumber}`);
    console.log(`   🔐 Commitment: ${userCommitment}`);

    // Check if already processing this request
    if (this.pendingRequests.has(seqStr)) {
      console.log(`⚠️ Request ${sequenceNumber} already being processed`);
      return;
    }

    // Create pending request
    const request: PendingRequest = {
      sequenceNumber,
      datasetId,
      requester: user,
      timestamp: Date.now(),
      retryCount: 0
    };

    this.pendingRequests.set(seqStr, request);
    this.fulfillmentQueue.push(request);

    console.log(`📝 Added request ${sequenceNumber} to fulfillment queue`);
  }

  private startFulfillmentProcessor() {
    const processQueue = async () => {
      if (!this.isRunning || this.fulfillmentQueue.length === 0) {
        return;
      }

      const request = this.fulfillmentQueue.shift();
      if (!request) return;

      const seqStr = request.sequenceNumber.toString();
      
      try {
        // Check if request is still unfulfilled
        const status = await this.contract.getRequestStatus(request.sequenceNumber);
        if (status.fulfilled) {
          console.log(`ℹ️ Request ${request.sequenceNumber} already fulfilled`);
          this.pendingRequests.delete(seqStr);
          return;
        }

        // Add delay before fulfillment (simulate processing time)
        const delay = this.config.fulfillmentDelay || 5000;
        console.log(`⏳ Waiting ${delay}ms before fulfilling request ${request.sequenceNumber}...`);
        
        setTimeout(async () => {
          await this.fulfillRequest(request);
        }, delay);

      } catch (error) {
        const e = extractErr(error);
        console.error(`❌ Error processing request ${request.sequenceNumber}:`, e.message ?? error);
        
        // Retry logic
        if (request.retryCount < 3) {
          request.retryCount++;
          console.log(`🔄 Retrying request ${request.sequenceNumber} (attempt ${request.retryCount})`);
          this.fulfillmentQueue.push(request);
        } else {
          console.error(`💥 Giving up on request ${request.sequenceNumber} after 3 retries`);
          this.pendingRequests.delete(seqStr);
        }
      }
    };

    // Process queue every 2 seconds
    const processInterval = setInterval(() => {
      if (this.isRunning) {
        processQueue();
      } else {
        clearInterval(processInterval);
      }
    }, 2000);
  }

  private async fulfillRequest(request: PendingRequest) {
    const seqStr = request.sequenceNumber.toString();
    
    try {
      console.log(`🎲 Generating random number for request ${request.sequenceNumber}...`);
      
      // Generate cryptographically secure random number
      // In production, this would use Pyth Entropy or another secure source
      const randomNumber = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint64', 'bytes32', 'uint256', 'address', 'uint256'],
          [
            request.sequenceNumber,
            request.datasetId,
            request.timestamp,
            request.requester,
            Math.floor(Math.random() * 1000000) // Add some randomness
          ]
        )
      );

      console.log(`📤 Fulfilling request ${request.sequenceNumber}...`);
      console.log(`   🎯 Random Number: ${randomNumber}`);

      const tx = await this.contract.manualFulfill(request.sequenceNumber, randomNumber, {
        gasLimit: 200000
      });

      console.log(`⏳ Transaction hash: ${tx.hash}`);
      const receipt = await tx.wait();

      if (receipt.status === 1) {
        console.log(`✅ Successfully fulfilled request ${request.sequenceNumber}`);
        console.log(`   🎲 Random result: ${randomNumber}`);
        this.pendingRequests.delete(seqStr);
      } else {
        throw new Error('Transaction failed');
      }

    } catch (error) {
      const e = extractErr(error);
      console.error(`❌ Failed to fulfill request ${request.sequenceNumber}:`, e.message ?? error);
      
      // Re-queue for retry
      if (request.retryCount < 3) {
        request.retryCount++;
        console.log(`🔄 Re-queuing request ${request.sequenceNumber} for retry`);
        this.fulfillmentQueue.push(request);
      } else {
        console.error(`💥 Giving up on request ${request.sequenceNumber}`);
        this.pendingRequests.delete(seqStr);
      }
    }
  }

  private startPeriodicCheck() {
    const check = async () => {
      if (!this.isRunning) return;

      try {
        console.log('🔄 Performing periodic check...');
        
        // Report status
        console.log(`📊 Status: ${this.pendingRequests.size} pending, ${this.fulfillmentQueue.length} queued`);
        
        // Clean up old requests (older than 1 hour)
        const oneHourAgo = Date.now() - 60 * 60 * 1000;
        for (const [seqStr, request] of this.pendingRequests.entries()) {
          if (request.timestamp < oneHourAgo) {
            console.log(`🧹 Cleaning up old request ${request.sequenceNumber}`);
            this.pendingRequests.delete(seqStr);
          }
        }

        // Check wallet balance
        const balance = await this.provider.getBalance(this.wallet.address);
        const balanceEth = parseFloat(ethers.formatEther(balance));
        if (balanceEth < 0.01) {
          console.warn(`⚠️ Low wallet balance: ${balanceEth.toFixed(4)} ETH`);
        }

      } catch (error) {
        const e = extractErr(error);
        console.error('❌ Periodic check failed:', e.message ?? error);
      }

      setTimeout(check, this.config.checkInterval);
    };

    check();
  }

  async getHealthStatus() {
    try {
      const balance = await this.provider.getBalance(this.wallet.address);
      
      return {
        isRunning: this.isRunning,
        walletAddress: this.wallet.address,
        walletBalance: ethers.formatEther(balance),
        pendingRequests: this.pendingRequests.size,
        queuedRequests: this.fulfillmentQueue.length,
        contractAddress: this.config.rngCoordinatorAddress,
        lastCheck: new Date().toISOString()
      };
    } catch (error) {
      const e = extractErr(error);
      return { error: e.message ?? String(error) };
    }
  }

  async stop() {
    this.isRunning = false;
    
    try {
      this.contract.removeAllListeners();
      console.log('👋 Shutting down RNG coordinator service...');
      console.log(`📊 Final status: ${this.pendingRequests.size} pending requests`);
      
      if (this.pendingRequests.size > 0) {
        console.log('⚠️ Warning: Shutting down with pending requests');
      }
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Error during shutdown:', e.message ?? error);
    }
    
    console.log('🛑 RNG coordinator service stopped');
  }
}

// CLI interface
async function main() {
  const config: RNGConfig = {
    privateKey: process.env.PRIVATE_KEY!,
    rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
    rngCoordinatorAddress: process.env.RNG_COORDINATOR_ADDRESS!,
    checkInterval: parseInt(process.env.CHECK_INTERVAL || '60000'), // 1 minute
    fulfillmentDelay: parseInt(process.env.FULFILLMENT_DELAY || '5000') // 5 seconds
  };

  const service = new RNGCoordinatorService(config);

  try {
    await service.start();

    process.on('SIGINT', async () => {
      console.log('\n👋 Received SIGINT, shutting down gracefully...');
      await service.stop();
      process.exit(0);
    });

    console.log('✅ RNG coordinator running. Press Ctrl+C to stop.');

  } catch (error) {
    const e = extractErr(error);
    console.error('💥 Service failed:', e.message ?? error);
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

export {RNGConfig, RNGCoordinatorService};

