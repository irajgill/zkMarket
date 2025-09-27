import lighthouse from '@lighthouse-web3/sdk';
import {createHash} from 'crypto';
import * as dotenv from 'dotenv';
import {ethers} from 'ethers';
import {readFileSync, writeFileSync} from 'fs';

dotenv.config();

interface UploadConfig {
  privateKey: string;
  lighthouseApiKey: string;
  synapseRpcUrl: string;
  datasetRegistryAddress: string;
  dataTokenAddress: string;
}

interface UploadResult {
  lighthouseCID: string;
  synapsePieceCID: string;
  merkleRoot: string;
  datasetId: string;
  txHash?: string;
}

class DataUploader {
  private config: UploadConfig;
  private provider: ethers.Provider;
  private wallet: ethers.Wallet;
  private synapse: any | null = null;

  constructor(config: UploadConfig) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(process.env.RPC_URL || 'http://localhost:8545');
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);
    console.log('📝 Uploader initialized for wallet:', this.wallet.address);
  }

  private async loadSynapse() {
    try {
      const mod: any = await import('@filoz/synapse-sdk');
      return { Synapse: mod.Synapse, RPC_URLS: mod.RPC_URLS };
    } catch {
      try {
        const mod: any = await import('@filoz/synapse-sdk/dist/index.js');
        return { Synapse: mod.Synapse, RPC_URLS: mod.RPC_URLS };
      } catch {
        return { Synapse: null, RPC_URLS: null };
      }
    }
  }

  async initialize() {
    try {
      const { Synapse, RPC_URLS } = await this.loadSynapse();
      if (!Synapse) {
        console.warn('⚠️ Synapse SDK not available; warm storage upload will be skipped in this run.');
        this.synapse = null;
        return;
      }
      const fallbackCalibrationWss = 'wss://wss.calibration.node.glif.io/apigw/lotus/rpc/v1';
      this.synapse = await Synapse.create({
        privateKey: this.config.privateKey,
        rpcURL: this.config.synapseRpcUrl || RPC_URLS?.calibration?.websocket || fallbackCalibrationWss,
      });
      console.log('🌐 Synapse SDK initialized');
    } catch (error) {
      console.error('❌ Failed to initialize Synapse:', error);
      this.synapse = null;
    }
  }

  async uploadFile(
    filePath: string,
    datasetName: string,
    description: string,
    accessControlConditions?: any[]
  ): Promise<UploadResult> {
    console.log(`📁 Starting upload for: ${filePath}`);

    try {
      const fileBuffer = readFileSync(filePath);
      const fileName = filePath.split('/').pop() || 'unknown';
      console.log(`📊 File size: ${fileBuffer.length} bytes`);

      const merkleRoot = this.calculateMerkleRoot(fileBuffer);
      console.log('🌳 Merkle root calculated:', merkleRoot);

      // 1) Lighthouse: encrypt + upload (+ ACC if working, otherwise skip)
      const lighthouseCID = await this.uploadToLighthouseEncrypted(filePath, fileName, accessControlConditions);
      console.log('🏠 Lighthouse upload complete. CID:', lighthouseCID);

      // 2) Synapse: optional warm storage
      let synapsePieceCID = '';
      if (this.synapse) {
        synapsePieceCID = await this.uploadToSynapse(fileBuffer, fileName);
        console.log('🗄️ Synapse upload complete. Piece CID:', synapsePieceCID);
      } else {
        console.warn('⚠️ Skipping Synapse upload (SDK unavailable in this environment).');
      }

      // 3) On-chain: register dataset
      const datasetId = await this.registerDataset(
        datasetName,
        description,
        merkleRoot,
        lighthouseCID,
        synapsePieceCID,
        fileBuffer.length
      );
      console.log('📋 Dataset registered. ID:', datasetId);

      const result: UploadResult = {
        lighthouseCID,
        synapsePieceCID,
        merkleRoot,
        datasetId,
      };

      this.saveUploadRecord(result, filePath, datasetName);
      return result;
    } catch (error) {
      console.error('❌ Upload failed:', error);
      throw error;
    }
  }

  private async uploadToLighthouseEncrypted(
    filePath: string,
    _fileName: string,
    accessControlConditions?: any[]
  ): Promise<string> {
    try {
      const publicKey = this.wallet.address;
      const auth = await lighthouse.getAuthMessage(publicKey);
      const messageRequested = (auth as any)?.data?.message as string | undefined;
      if (!messageRequested) {
        throw new Error('Failed to retrieve authentication message from Lighthouse.');
      }
      const signedMessage = await this.wallet.signMessage(messageRequested);

      // Encrypted upload (required for access control)
      const enc: any = await lighthouse.uploadEncrypted(
        filePath,
        this.config.lighthouseApiKey,
        publicKey,
        signedMessage
      );
      const cid: string | undefined = enc?.data?.[0]?.Hash || enc?.data?.Hash;
      if (!cid) throw new Error('Lighthouse uploadEncrypted returned no CID');

      // Try to apply access control with multiple fallback strategies
      if (accessControlConditions && accessControlConditions.length > 0) {
        console.log('🔐 Applying access control conditions...');
        
        const success = await this.tryApplyAccessControl(
          publicKey,
          cid,
          signedMessage,
          accessControlConditions
        );
        
        if (success) {
          console.log('✅ Access control applied successfully');
        } else {
          console.warn('⚠️ Access control failed, but file uploaded successfully. Manual gating may be needed.');
        }
      }

      return cid;
    } catch (error) {
      console.error('❌ Lighthouse upload failed:', error);
      throw error;
    }
  }

  private async tryApplyAccessControl(
    publicKey: string,
    cid: string,
    signedMessage: string,
    conditions: any[]
  ): Promise<boolean> {
    // Strategy 1: Standard format with Ethereum chain
    try {
      console.log('🔄 Trying standard access control format...');
      const ethereumConditions = conditions.map(c => ({
        ...c,
        chain: "Ethereum" // Use Ethereum instead of Base
      }));
      
      await lighthouse.applyAccessCondition(
        publicKey,
        cid,
        signedMessage,
        ethereumConditions,
        "([1])"
      );
      return true;
    } catch (e: any) {
      console.log('❌ Standard format failed:', e?.message?.substring(0, 100));
    }

    // Strategy 2: JSON string format
    try {
      console.log('🔄 Trying JSON string format...');
      await lighthouse.applyAccessCondition(
        publicKey,
        cid,
        signedMessage,
        JSON.stringify(conditions),
        "([1])"
      );
      return true;
    } catch (e: any) {
      console.log('❌ JSON string format failed:', e?.message?.substring(0, 100));
    }

    // Strategy 3: Simplified aggregator
    try {
      console.log('🔄 Trying simplified aggregator...');
      await lighthouse.applyAccessCondition(
        publicKey,
        cid,
        signedMessage,
        conditions,
        "[1]"
      );
      return true;
    } catch (e: any) {
      console.log('❌ Simplified aggregator failed:', e?.message?.substring(0, 100));
    }

    // Strategy 4: ERC20-like format as fallback (skip custom contract)
    try {
      console.log('🔄 Trying fallback without custom conditions...');
      console.log('⚠️ Skipping access control due to compatibility issues');
      return false; // Don't apply any access control
    } catch (e: any) {
      console.log('❌ All access control strategies failed');
    }

    return false;
  }

  private async uploadToSynapse(fileBuffer: Buffer, _fileName: string): Promise<string> {
    try {
      if (!this.synapse) throw new Error('Synapse SDK not initialized');
      const uploadResult = await this.synapse.storage.upload(fileBuffer);
      console.log('📦 Synapse upload result:', uploadResult);
      const piece = uploadResult?.pieceCid || uploadResult?.cid;
      if (!piece) throw new Error('Synapse upload returned no CID');
      return piece;
    } catch (error) {
      console.error('❌ Synapse upload failed:', error);
      throw error;
    }
  }

  private async registerDataset(
    name: string,
    description: string,
    merkleRoot: string,
    lighthouseCID: string,
    synapsePieceCID: string,
    size: number
  ): Promise<string> {
    try {
      const registryABI = [
        'function registerDataset(string name, string description, bytes32 merkleRoot, string lighthouseCID, string synapsePieceCID, uint256 size, string[] metadataKeys, string[] metadataValues) returns (bytes32)',
      ];
      const registry = new ethers.Contract(
        this.config.datasetRegistryAddress,
        registryABI,
        this.wallet
      );

      const metadataKeys = ['fileName', 'uploadedAt', 'uploader'];
      const metadataValues = [name, new Date().toISOString(), this.wallet.address];

      const tx = await registry.registerDataset(
        name,
        description,
        merkleRoot,
        lighthouseCID,
        synapsePieceCID,
        size,
        metadataKeys,
        metadataValues
      );
      console.log('⏳ Waiting for transaction confirmation...');
      const receipt = await tx.wait();

      const topic = ethers.id('DatasetRegistered(bytes32,address,string,string,string)');
      const event = receipt.logs.find((log: any) => log.topics?.[0] === topic);
      const datasetId =
        event?.topics?.[1] ??
        ethers.keccak256(
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address', 'string', 'string', 'uint256'],
            [this.wallet.address, name, lighthouseCID, Date.now()]
          )
        );

      return datasetId;
    } catch (error) {
      console.error('❌ Dataset registration failed:', error);
      throw error;
    }
  }

  private calculateMerkleRoot(data: Buffer): string {
    const hash = createHash('sha256').update(data).digest();
    return '0x' + hash.toString('hex');
  }

  private saveUploadRecord(result: UploadResult, filePath: string, datasetName: string) {
    const record = {
      timestamp: new Date().toISOString(),
      filePath,
      datasetName,
      uploader: this.wallet.address,
      ...result,
    };
    const recordsFile = 'upload-records.json';
    let records: any[] = [];
    try {
      records = JSON.parse(readFileSync(recordsFile, 'utf8'));
    } catch {
      // ignore
    }
    records.push(record);
    writeFileSync(recordsFile, JSON.stringify(records, null, 2));
    console.log('💾 Upload record saved');
  }

  async createLighthouseAccessCondition(datasetId: string): Promise<any[]> {
    return [
      {
        id: 1,
        chain: 'Ethereum', // Changed from 'Base' to 'Ethereum' for better compatibility
        method: 'hasAccess',
        standardContractType: 'Custom',
        contractAddress: this.config.dataTokenAddress,
        parameters: [datasetId, ':userAddress'],
        returnValueTest: { comparator: '==', value: 'true' },
      },
    ];
  }

  async cleanup() {
    try {
      if (this.synapse) {
        const provider = this.synapse.getProvider?.();
        if (provider && typeof provider.destroy === 'function') {
          await provider.destroy();
        }
      }
      console.log('🧹 Cleanup completed');
    } catch (error) {
      console.error('❌ Cleanup failed:', error);
    }
  }
}

// CLI
async function main() {
  const fallbackCalibrationWss = 'wss://wss.calibration.node.glif.io/apigw/lotus/rpc/v1';
  const config: UploadConfig = {
    privateKey: process.env.PRIVATE_KEY!,
    lighthouseApiKey: process.env.LIGHTHOUSE_API_KEY!,
    synapseRpcUrl: process.env.SYNAPSE_RPC_URL || fallbackCalibrationWss,
    datasetRegistryAddress: process.env.DATASET_REGISTRY_ADDRESS!,
    dataTokenAddress: process.env.DATA_TOKEN_ADDRESS!,
  };

  const uploader = new DataUploader(config);
  await uploader.initialize();

  const args = process.argv.slice(2);
  if (args.length < 3) {
    console.log(
      'Usage: npx ts-node uploader.ts <filePath> <datasetName> <description> [--with-access-control]'
    );
    process.exit(1);
  }

  const [filePath, datasetName, description] = args;
  const withAccessControl = args.includes('--with-access-control');

  try {
    let accessConditions;
    if (withAccessControl) {
      const tempDatasetId = ethers.keccak256(
        ethers.toUtf8Bytes(datasetName + Date.now())
      );
      accessConditions = await uploader.createLighthouseAccessCondition(tempDatasetId);
      console.log('🔍 Generated access conditions:', JSON.stringify(accessConditions, null, 2));
    }

    const result = await uploader.uploadFile(
      filePath,
      datasetName,
      description,
      accessConditions
    );

    console.log('\n🎉 Upload completed successfully!');
    console.log('📋 Results:', JSON.stringify(result, null, 2));
  } catch (error) {
    console.error('💥 Upload failed:', error);
    process.exit(1);
  } finally {
    await uploader.cleanup();
  }
}

if (require.main === module) {
  main().catch(console.error);
}

export {DataUploader, UploadResult};



