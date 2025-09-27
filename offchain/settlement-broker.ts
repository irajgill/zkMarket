import * as dotenv from 'dotenv';
import {ethers} from 'ethers';

dotenv.config();

interface SettlementConfig {
  privateKey: string;
  rpcUrl: string;
  crossChainEscrowAddress: string;
  dataTokenAddress: string;
  datasetRegistryAddress: string;
  checkInterval: number;
  settlementDelay: number;
  disputeWindow: number;
}

interface EscrowTransaction {
  transactionId: string;
  buyer: string;
  seller: string;
  datasetId: string;
  amount: bigint;
  status: 'PENDING' | 'DISPUTED' | 'READY_FOR_SETTLEMENT' | 'SETTLED' | 'REFUNDED';
  createdAt: number;
  disputeDeadline: number;
  retryCount: number;
}

interface DisputeCase {
  transactionId: string;
  disputant: string;
  reason: string;
  evidence: string;
  timestamp: number;
}

function extractErr(e: unknown): { code?: string; message?: string } {
  if (typeof e === 'object' && e !== null) {
    const anyE = e as any;
    return { code: anyE?.code, message: anyE?.message };
  }
  return {};
}

class SettlementBrokerService {
  private config: SettlementConfig;
  private provider: ethers.Provider;
  private wallet: ethers.Wallet;
  private escrowContract: ethers.Contract;
  private dataTokenContract: ethers.Contract;
  private registryContract: ethers.Contract;
  private isRunning = false;
  
  // Transaction tracking
  private pendingTransactions = new Map<string, EscrowTransaction>();
  private settlementQueue: EscrowTransaction[] = [];
  private disputes = new Map<string, DisputeCase>();
  
  constructor(config: SettlementConfig) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);

    // CrossChainEscrow contract ABI - simplified for compatibility
    const escrowABI = [
      "function createEscrow(bytes32 datasetId, address seller, uint256 amount, uint256 disputeWindow) external returns (bytes32 transactionId)",
      "function releaseEscrow(bytes32 transactionId) external",
      "function refundEscrow(bytes32 transactionId) external",
      "function disputeEscrow(bytes32 transactionId, string calldata reason, string calldata evidence) external",
      "function resolveDispute(bytes32 transactionId, bool releaseToSeller) external",
      "function getEscrowDetails(bytes32 transactionId) external view returns (address buyer, address seller, bytes32 datasetId, uint256 amount, uint8 status, uint256 createdAt, uint256 disputeDeadline)",
      // Make isAuthorizedBroker optional - might not exist in contract
      "function isAuthorizedBroker(address broker) external view returns (bool)",
      "event EscrowCreated(bytes32 indexed transactionId, address indexed buyer, address indexed seller, bytes32 datasetId, uint256 amount)",
      "event EscrowReleased(bytes32 indexed transactionId, address indexed buyer, address indexed seller, uint256 amount)",
      "event EscrowRefunded(bytes32 indexed transactionId, address indexed buyer, uint256 amount)",
      "event EscrowDisputed(bytes32 indexed transactionId, address indexed disputant, string reason)",
      "event DisputeResolved(bytes32 indexed transactionId, address indexed resolver, bool releasedToSeller)"
    ];

    this.escrowContract = new ethers.Contract(config.crossChainEscrowAddress, escrowABI, this.wallet);

    // DataToken contract ABI
    const tokenABI = [
      "function transfer(address to, uint256 amount) external returns (bool)",
      "function transferFrom(address from, address to, uint256 amount) external returns (bool)",
      "function balanceOf(address account) external view returns (uint256)",
      "function allowance(address owner, address spender) external view returns (uint256)",
      "function name() external view returns (string)",
      "function symbol() external view returns (string)",
      "function decimals() external view returns (uint8)"
    ];

    this.dataTokenContract = new ethers.Contract(config.dataTokenAddress, tokenABI, this.wallet);

    // Dataset Registry ABI
    const registryABI = [
      "function getDatasetOwner(bytes32 datasetId) external view returns (address)",
      "function isDatasetActive(bytes32 datasetId) external view returns (bool)",
      "function getDatasetMetadata(bytes32 datasetId) external view returns (string memory name, string memory description, uint256 size)"
    ];

    this.registryContract = new ethers.Contract(config.datasetRegistryAddress, registryABI, this.wallet);

    console.log('🤝 Settlement Broker initialized');
    console.log('   📍 Escrow Address:', config.crossChainEscrowAddress);
    console.log('   🪙 Token Address:', config.dataTokenAddress);
    console.log('   💰 Broker Address:', this.wallet.address);
  }

  async start() {
    this.isRunning = true;
    console.log('🚀 Starting settlement broker service...');

    try {
      // Test connection with better error handling
      await this.testConnection();
      
      // Setup event listeners
      this.setupEventListeners();
      
      // Start monitoring and settlement processes
      this.startEscrowMonitoring();
      this.startSettlementProcessor();
      this.startDisputeProcessor();
      
      console.log('✅ Settlement broker service started');
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Failed to start settlement broker:', e.message ?? error);
      throw error;
    }
  }

  private async testConnection() {
    try {
      console.log('🔍 Testing connections...');
      
      // Test basic provider connection
      const balance = await this.provider.getBalance(this.wallet.address);
      console.log('💰 Broker wallet balance:', ethers.formatEther(balance), 'ETH');
      
      // Test token contract connection
      try {
        const tokenBalance = await this.dataTokenContract.balanceOf(this.wallet.address);
        console.log('🪙 Token balance:', ethers.formatUnits(tokenBalance, 18), 'DATA');
        
        // Try to get token info
        const tokenName = await this.dataTokenContract.name();
        const tokenSymbol = await this.dataTokenContract.symbol();
        console.log(`📄 Token: ${tokenName} (${tokenSymbol})`);
      } catch (error) {
        console.warn('⚠️ Token contract test failed, but continuing...');
      }
      
      // Test escrow contract with safer approach
      try {
        console.log('🔍 Testing escrow contract...');
        
        // Try calling isAuthorizedBroker if it exists
        try {
          const isAuthorized = await this.escrowContract.isAuthorizedBroker(this.wallet.address);
          if (!isAuthorized) {
            console.warn('⚠️ Warning: Wallet is not authorized as broker in escrow contract');
          } else {
            console.log('✅ Broker authorization verified');
          }
        } catch (authError) {
          console.log('ℹ️ Authorization check not available (function may not exist)');
        }
        
        // Test with a dummy transaction ID to verify contract connectivity
        const dummyTxId = '0x0000000000000000000000000000000000000000000000000000000000000001';
        try {
          await this.escrowContract.getEscrowDetails(dummyTxId);
        } catch (error) {
          const e = extractErr(error);
          if (e.message?.includes('call revert exception') || e.message?.includes('execution reverted')) {
            console.log('✅ Escrow contract connection verified (expected revert for dummy transaction)');
          } else {
            throw error;
          }
        }
        
      } catch (error) {
        console.warn('⚠️ Escrow contract test had issues, but continuing...');
        console.log('   Contract might not be deployed or ABI might not match');
      }
      
      // Test registry contract
      try {
        console.log('🔍 Testing registry contract...');
        const dummyDatasetId = '0x0000000000000000000000000000000000000000000000000000000000000001';
        try {
          await this.registryContract.getDatasetOwner(dummyDatasetId);
        } catch (error) {
          const e = extractErr(error);
          if (e.message?.includes('call revert exception') || e.message?.includes('execution reverted')) {
            console.log('✅ Registry contract connection verified (expected revert for dummy dataset)');
          } else {
            throw error;
          }
        }
      } catch (error) {
        console.warn('⚠️ Registry contract test had issues, but continuing...');
      }
      
      console.log('✅ Connection tests completed');
      
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Connection test failed:', e.message ?? error);
      throw error;
    }
  }

  private setupEventListeners() {
    try {
      console.log('👂 Setting up event listeners...');
      
      // Listen for new escrows
      this.escrowContract.on('EscrowCreated', this.handleEscrowCreated.bind(this));
      
      // Listen for disputes
      this.escrowContract.on('EscrowDisputed', this.handleEscrowDisputed.bind(this));
      
      // Listen for manual releases/refunds (for cleanup)
      this.escrowContract.on('EscrowReleased', this.handleEscrowReleased.bind(this));
      this.escrowContract.on('EscrowRefunded', this.handleEscrowRefunded.bind(this));
      
      console.log('✅ Event listeners configured');
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Failed to setup event listeners:', e.message ?? error);
      // Don't throw here, allow service to continue without events
      console.warn('⚠️ Continuing without event listeners...');
    }
  }

  private async handleEscrowCreated(
    transactionId: string,
    buyer: string,
    seller: string,
    datasetId: string,
    amount: bigint
  ) {
    console.log('🆕 New escrow created:');
    console.log(`   📄 Transaction ID: ${transactionId}`);
    console.log(`   🛒 Buyer: ${buyer}`);
    console.log(`   🏪 Seller: ${seller}`);
    console.log(`   📊 Dataset ID: ${datasetId}`);
    console.log(`   💰 Amount: ${ethers.formatUnits(amount, 18)} DATA`);

    try {
      // Get full escrow details
      const details = await this.escrowContract.getEscrowDetails(transactionId);
      
      const transaction: EscrowTransaction = {
        transactionId,
        buyer: details.buyer,
        seller: details.seller,
        datasetId: details.datasetId,
        amount: details.amount,
        status: 'PENDING',
        createdAt: Number(details.createdAt),
        disputeDeadline: Number(details.disputeDeadline),
        retryCount: 0
      };

      this.pendingTransactions.set(transactionId, transaction);
      
      // Verify dataset and seller
      await this.verifyTransaction(transaction);
      
    } catch (error) {
      const e = extractErr(error);
      console.error(`❌ Failed to process new escrow ${transactionId}:`, e.message ?? error);
    }
  }

  private async handleEscrowDisputed(
    transactionId: string,
    disputant: string,
    reason: string
  ) {
    console.log('⚖️ Escrow dispute filed:');
    console.log(`   📄 Transaction ID: ${transactionId}`);
    console.log(`   👤 Disputant: ${disputant}`);
    console.log(`   📝 Reason: ${reason}`);

    const transaction = this.pendingTransactions.get(transactionId);
    if (transaction) {
      transaction.status = 'DISPUTED';
      
      const dispute: DisputeCase = {
        transactionId,
        disputant,
        reason,
        evidence: '', // Would be retrieved from contract or IPFS
        timestamp: Date.now()
      };
      
      this.disputes.set(transactionId, dispute);
      
      console.log(`🔍 Dispute case created for transaction ${transactionId}`);
    }
  }

  private async handleEscrowReleased(transactionId: string, buyer: string, seller: string, amount: bigint) {
    console.log(`✅ Escrow released: ${transactionId} (${ethers.formatUnits(amount, 18)} DATA to ${seller})`);
    this.pendingTransactions.delete(transactionId);
    this.disputes.delete(transactionId);
  }

  private async handleEscrowRefunded(transactionId: string, buyer: string, amount: bigint) {
    console.log(`🔄 Escrow refunded: ${transactionId} (${ethers.formatUnits(amount, 18)} DATA to ${buyer})`);
    this.pendingTransactions.delete(transactionId);
    this.disputes.delete(transactionId);
  }

  private async verifyTransaction(transaction: EscrowTransaction) {
    try {
      console.log(`🔍 Verifying transaction ${transaction.transactionId}...`);
      
      // Verify dataset exists and seller owns it (with error handling)
      try {
        const datasetOwner = await this.registryContract.getDatasetOwner(transaction.datasetId);
        const isActive = await this.registryContract.isDatasetActive(transaction.datasetId);
        
        if (datasetOwner.toLowerCase() !== transaction.seller.toLowerCase()) {
          console.error(`❌ Seller verification failed for ${transaction.transactionId}: owner mismatch`);
          this.queueForRefund(transaction, 'Seller does not own dataset');
          return;
        }
        
        if (!isActive) {
          console.error(`❌ Dataset verification failed for ${transaction.transactionId}: dataset inactive`);
          this.queueForRefund(transaction, 'Dataset is not active');
          return;
        }
        
        console.log(`✅ Transaction ${transaction.transactionId} verified successfully`);
      } catch (error) {
        console.warn(`⚠️ Could not verify dataset for ${transaction.transactionId}, proceeding anyway`);
      }
      
      // Queue for settlement after dispute window
      transaction.status = 'READY_FOR_SETTLEMENT';
      this.settlementQueue.push(transaction);
      
    } catch (error) {
      const e = extractErr(error);
      console.error(`❌ Verification failed for ${transaction.transactionId}:`, e.message ?? error);
    }
  }

  private queueForRefund(transaction: EscrowTransaction, reason: string) {
    console.log(`🔄 Queuing refund for ${transaction.transactionId}: ${reason}`);
    transaction.status = 'REFUNDED';
    // In a real implementation, you might want to add a refund queue
  }

  private startEscrowMonitoring() {
    const monitor = async () => {
      if (!this.isRunning) return;

      try {
        console.log('🔍 Monitoring escrow transactions...');
        console.log(`📊 Status: ${this.pendingTransactions.size} pending, ${this.settlementQueue.length} queued, ${this.disputes.size} disputed`);
        
        const currentTime = Math.floor(Date.now() / 1000);
        
        for (const [txId, transaction] of this.pendingTransactions.entries()) {
          // Check if dispute window has expired for non-disputed transactions
          if (
            transaction.status === 'READY_FOR_SETTLEMENT' && 
            currentTime > transaction.disputeDeadline &&
            !this.disputes.has(txId)
          ) {
            console.log(`⏰ Dispute window expired for ${txId}, queuing for settlement`);
            if (!this.settlementQueue.find(t => t.transactionId === txId)) {
              this.settlementQueue.push(transaction);
            }
          }
        }
        
      } catch (error) {
        const e = extractErr(error);
        console.error('❌ Escrow monitoring failed:', e.message ?? error);
      }

      setTimeout(monitor, this.config.checkInterval);
    };

    monitor();
  }

  private startSettlementProcessor() {
    const processSettlements = async () => {
      if (!this.isRunning || this.settlementQueue.length === 0) {
        return;
      }

      const transaction = this.settlementQueue.shift();
      if (!transaction || transaction.status === 'DISPUTED') {
        return;
      }

      try {
        await this.settleTransaction(transaction);
      } catch (error) {
        const e = extractErr(error);
        console.error(`❌ Settlement processing failed for ${transaction.transactionId}:`, e.message ?? error);
        
        // Retry logic
        if (transaction.retryCount < 3) {
          transaction.retryCount++;
          this.settlementQueue.push(transaction);
          console.log(`🔄 Retrying settlement for ${transaction.transactionId} (attempt ${transaction.retryCount})`);
        }
      }
    };

    // Process settlements every 10 seconds
    const processInterval = setInterval(() => {
      if (this.isRunning) {
        processSettlements();
      } else {
        clearInterval(processInterval);
      }
    }, 10000);
  }

  private async settleTransaction(transaction: EscrowTransaction) {
    console.log(`💰 Settling transaction ${transaction.transactionId}...`);
    
    try {
      // Final verification before settlement
      const details = await this.escrowContract.getEscrowDetails(transaction.transactionId);
      
      // Status: 0 = PENDING, 1 = RELEASED, 2 = REFUNDED, 3 = DISPUTED
      if (details.status === 1) {
        console.log(`ℹ️ Transaction ${transaction.transactionId} already settled`);
        this.pendingTransactions.delete(transaction.transactionId);
        return;
      }

      if (details.status === 3) {
        console.log(`⚖️ Transaction ${transaction.transactionId} is disputed, skipping auto-settlement`);
        return;
      }

      // Execute settlement
      const tx = await this.escrowContract.releaseEscrow(transaction.transactionId, {
        gasLimit: 300000
      });

      console.log(`📤 Settlement transaction sent: ${tx.hash}`);
      const receipt = await tx.wait();

      if (receipt.status === 1) {
        console.log(`✅ Transaction ${transaction.transactionId} settled successfully`);
        console.log(`   💸 Released ${ethers.formatUnits(transaction.amount, 18)} DATA to ${transaction.seller}`);
        
        transaction.status = 'SETTLED';
        this.pendingTransactions.delete(transaction.transactionId);
      } else {
        throw new Error('Settlement transaction failed');
      }

    } catch (error) {
      const e = extractErr(error);
      console.error(`❌ Settlement failed for ${transaction.transactionId}:`, e.message ?? error);
      throw error;
    }
  }

  private startDisputeProcessor() {
    const processDisputes = async () => {
      if (!this.isRunning) return;

      try {
        if (this.disputes.size > 0) {
          console.log('⚖️ Processing disputes...');
          
          for (const [txId, dispute] of this.disputes.entries()) {
            const disputeAge = Date.now() - dispute.timestamp;
            
            // Auto-resolve disputes older than 24 hours (example logic)
            if (disputeAge > 24 * 60 * 60 * 1000) {
              console.log(`🕐 Auto-resolving old dispute for ${txId}`);
              await this.autoResolveDispute(txId, dispute);
            }
          }
        }
        
      } catch (error) {
        const e = extractErr(error);
        console.error('❌ Dispute processing failed:', e.message ?? error);
      }

      setTimeout(processDisputes, this.config.checkInterval * 2); // Check every 2 minutes
    };

    processDisputes();
  }

  private async autoResolveDispute(transactionId: string, dispute: DisputeCase) {
    try {
      console.log(`🤖 Auto-resolving dispute for ${transactionId}...`);
      
      // Simple auto-resolution logic (in production, this would be more sophisticated)
      // For demo, we'll favor the seller if the reason doesn't indicate fraud
      const favorSeller = !dispute.reason.toLowerCase().includes('fraud') && 
                         !dispute.reason.toLowerCase().includes('fake') &&
                         !dispute.reason.toLowerCase().includes('scam');
      
      const tx = await this.escrowContract.resolveDispute(transactionId, favorSeller, {
        gasLimit: 200000
      });
      
      const receipt = await tx.wait();
      
      if (receipt.status === 1) {
        console.log(`✅ Dispute resolved for ${transactionId}, ${favorSeller ? 'released to seller' : 'refunded to buyer'}`);
        this.disputes.delete(transactionId);
        this.pendingTransactions.delete(transactionId);
      }
      
    } catch (error) {
      const e = extractErr(error);
      console.error(`❌ Auto-resolution failed for ${transactionId}:`, e.message ?? error);
    }
  }

  async getHealthStatus() {
    try {
      const balance = await this.provider.getBalance(this.wallet.address);
      
      let tokenBalance = '0';
      try {
        const tokenBal = await this.dataTokenContract.balanceOf(this.wallet.address);
        tokenBalance = ethers.formatUnits(tokenBal, 18);
      } catch (error) {
        tokenBalance = 'Error reading balance';
      }
      
      return {
        isRunning: this.isRunning,
        brokerAddress: this.wallet.address,
        ethBalance: ethers.formatEther(balance),
        tokenBalance,
        pendingTransactions: this.pendingTransactions.size,
        settlementQueue: this.settlementQueue.length,
        activeDisputes: this.disputes.size,
        contractAddresses: {
          escrow: this.config.crossChainEscrowAddress,
          token: this.config.dataTokenAddress,
          registry: this.config.datasetRegistryAddress
        },
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
      this.escrowContract.removeAllListeners();
      console.log('👋 Shutting down settlement broker...');
      console.log(`📊 Final status: ${this.pendingTransactions.size} pending, ${this.disputes.size} disputed`);
    } catch (error) {
      const e = extractErr(error);
      console.error('❌ Error during shutdown:', e.message ?? error);
    }
    
    console.log('🛑 Settlement broker service stopped');
  }
}

// CLI interface
async function main() {
  const config: SettlementConfig = {
    privateKey: process.env.PRIVATE_KEY!,
    rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
    crossChainEscrowAddress: process.env.CROSS_CHAIN_ESCROW_ADDRESS!,
    dataTokenAddress: process.env.DATA_TOKEN_ADDRESS!,
    datasetRegistryAddress: process.env.DATASET_REGISTRY_ADDRESS!,
    checkInterval: parseInt(process.env.CHECK_INTERVAL || '60000'), // 1 minute
    settlementDelay: parseInt(process.env.SETTLEMENT_DELAY || '10000'), // 10 seconds
    disputeWindow: parseInt(process.env.DISPUTE_WINDOW || '3600') // 1 hour
  };

  const service = new SettlementBrokerService(config);

  try {
    await service.start();

    process.on('SIGINT', async () => {
      console.log('\n👋 Received SIGINT, shutting down gracefully...');
      await service.stop();
      process.exit(0);
    });

    console.log('✅ Settlement broker running. Press Ctrl+C to stop.');

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

export {SettlementBrokerService, SettlementConfig};


