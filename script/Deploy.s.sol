// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DataToken1155} from "../contracts/DataToken1155.sol";
import {PricingOracleAdapter} from "../contracts/PricingOracleAdapter.sol";
import {RNGCoordinator} from "../contracts/RNGCoordinator.sol";
import {CrossChainEscrow} from "../contracts/CrossChainEscrow.sol";
import {DatasetRegistry} from "../contracts/DatasetRegistry.sol";
import {MockPyth} from "../contracts/mocks/MockPyth.sol";
import {MockEntropy} from "../contracts/mocks/MockEntropy.sol";
import {MockSelfHub} from "../contracts/mocks/MockSelfHub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

contract DeployScript is Script {
    // Configuration
    struct DeployConfig {
        address pythContract;
        address entropyContract;
        address selfHubContract;
        bytes32 btcUsdPriceId;
        uint32 maxStaleness;
        string dataTokenURI;
        bool useMocks;
    }

    // Deployed contract addresses
    struct DeployedContracts {
        address mockPyth;
        address mockEntropy;
        address mockSelfHub;
        address dataToken1155;
        address pricingOracle;
        address rngCoordinator;
        address crossChainEscrow;
        address datasetRegistry;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying with account:", deployer);
        console.log("Account balance:", deployer.balance);

        // Get configuration
        DeployConfig memory config = getDeployConfig();

        vm.startBroadcast(deployerPrivateKey);

        DeployedContracts memory contracts = deployAllContracts(config, deployer);

        vm.stopBroadcast();

        // Log all deployed addresses
        logDeployedAddresses(contracts);

        // Save deployment info
        saveDeploymentInfo(contracts);

        console.log("\n[SUCCESS] Deployment completed successfully!");
    }

    function getDeployConfig() internal view returns (DeployConfig memory) {
        uint256 chainId = block.chainid;

        // Default to mocks for local/test deployment
        bool useMocks = chainId == 31337 || chainId == 1337; // Anvil/Hardhat

        if (useMocks) {
            return DeployConfig({
                pythContract: address(0), // Will deploy mock
                entropyContract: address(0), // Will deploy mock
                selfHubContract: address(0), // Will deploy mock
                btcUsdPriceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
                maxStaleness: 60, // 60 seconds
                dataTokenURI: "https://api.zk-marketplace.com/metadata/{id}",
                useMocks: true
            });
        } else {
            // Production configuration
            // These addresses should be set via environment variables
            return DeployConfig({
                pythContract: vm.envAddress("PYTH_CONTRACT_ADDRESS"),
                entropyContract: vm.envAddress("ENTROPY_CONTRACT_ADDRESS"),
                selfHubContract: vm.envAddress("SELF_HUB_CONTRACT_ADDRESS"),
                btcUsdPriceId: vm.envBytes32("BTC_USD_PRICE_ID"),
                maxStaleness: uint32(vm.envUint("MAX_STALENESS")),
                dataTokenURI: vm.envString("DATA_TOKEN_URI"),
                useMocks: false
            });
        }
    }

    function deployAllContracts(
        DeployConfig memory config,
        address deployer
    ) internal returns (DeployedContracts memory contracts) {

        console.log("\n[INFO] Starting contract deployment...");

        // Deploy mocks if needed
        if (config.useMocks) {
            contracts.mockPyth = deployMockPyth();
            contracts.mockEntropy = deployMockEntropy();
            contracts.mockSelfHub = deployMockSelfHub();

            // Update config to use mocks
            config.pythContract = contracts.mockPyth;
            config.entropyContract = contracts.mockEntropy;
            config.selfHubContract = contracts.mockSelfHub;
        }

        // Deploy main contracts
        contracts.datasetRegistry = deployDatasetRegistry();
        contracts.dataToken1155 = deployDataToken1155(
            config.selfHubContract,
            config.dataTokenURI
        );
        contracts.pricingOracle = deployPricingOracle(
            config.pythContract,
            config.btcUsdPriceId,
            config.maxStaleness,
            deployer
        );
        contracts.rngCoordinator = deployRNGCoordinator(
            config.entropyContract,
            deployer
        );
        contracts.crossChainEscrow = deployCrossChainEscrow(deployer);

        console.log("\n[SUCCESS] Deployment completed successfully!");

        return contracts;
    }

    function deployMockPyth() internal returns (address) {
        console.log("[INFO] Deploying MockPyth...");
        MockPyth mockPyth = new MockPyth();

        // Set initial BTC price
        mockPyth.setPrice(
            0xe62df6c8b4c85fe1b5a04b3a0e3bd6f7e3c7f6b8c4c85fe1b5a04b3a0e3bd6f7,
            45000 * 1e8, // $45,000
            -8 // 8 decimal places
        );

        console.log("  MockPyth deployed at:", address(mockPyth));
        return address(mockPyth);
    }

    function deployMockEntropy() internal returns (address) {
        console.log("[INFO] Deploying MockEntropy...");
        MockEntropy mockEntropy = new MockEntropy();
        console.log("  MockEntropy deployed at:", address(mockEntropy));
        return address(mockEntropy);
    }

    function deployMockSelfHub() internal returns (address) {
        console.log("[INFO] Deploying MockSelfHub...");
        MockSelfHub mockSelfHub = new MockSelfHub();
        console.log("  MockSelfHub deployed at:", address(mockSelfHub));
        return address(mockSelfHub);
    }

    function deployDatasetRegistry() internal returns (address) {
        console.log("[INFO] Deploying DatasetRegistry...");
        DatasetRegistry registry = new DatasetRegistry();
        console.log("  DatasetRegistry deployed at:", address(registry));
        return address(registry);
    }

    function deployDataToken1155(
        address selfHub,
        string memory uri
    ) internal returns (address) {
        console.log("[INFO] Deploying DataToken1155...");

        // Deploy implementation
        DataToken1155 impl = new DataToken1155();
        console.log("  DataToken1155 implementation:", address(impl));

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            DataToken1155.initialize.selector,
            selfHub,
            "zk-marketplace-scope",
            uri
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("  DataToken1155 proxy deployed at:", address(proxy));

        return address(proxy);
    }

    function deployPricingOracle(
        address pythContract,
        bytes32 priceId,
        uint32 maxStaleness,
        address owner
    ) internal returns (address) {
        console.log("[INFO] Deploying PricingOracleAdapter...");

        PricingOracleAdapter oracle = new PricingOracleAdapter(
            IPyth(pythContract),
            priceId,
            maxStaleness,
            owner
        );

        console.log("  PricingOracleAdapter deployed at:", address(oracle));
        return address(oracle);
    }

    function deployRNGCoordinator(
        address entropyContract,
        address owner
    ) internal returns (address) {
        console.log("[INFO] Deploying RNGCoordinator...");

        RNGCoordinator rng = new RNGCoordinator(entropyContract, owner);

        console.log("  RNGCoordinator deployed at:", address(rng));
        return address(rng);
    }

    function deployCrossChainEscrow(address owner) internal returns (address) {
        console.log("[INFO] Deploying CrossChainEscrow...");

        CrossChainEscrow escrow = new CrossChainEscrow(owner);

        console.log("  CrossChainEscrow deployed at:", address(escrow));
        return address(escrow);
    }

    function logDeployedAddresses(DeployedContracts memory contracts) internal view {
        console.log("\n[INFO] Deployed Contract Addresses:");
        console.log("================================");

        if (contracts.mockPyth != address(0)) {
            console.log("MockPyth:", contracts.mockPyth);
        }
        if (contracts.mockEntropy != address(0)) {
            console.log("MockEntropy:", contracts.mockEntropy);
        }
        if (contracts.mockSelfHub != address(0)) {
            console.log("MockSelfHub:", contracts.mockSelfHub);
        }

        console.log("DataToken1155:", contracts.dataToken1155);
        console.log("PricingOracleAdapter:", contracts.pricingOracle);
        console.log("RNGCoordinator:", contracts.rngCoordinator);
        console.log("CrossChainEscrow:", contracts.crossChainEscrow);
        console.log("DatasetRegistry:", contracts.datasetRegistry);
    }

    function saveDeploymentInfo(DeployedContracts memory contracts) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory json = "deployment";

        // Build JSON object
        vm.serializeAddress(json, "dataToken1155", contracts.dataToken1155);
        vm.serializeAddress(json, "pricingOracle", contracts.pricingOracle);
        vm.serializeAddress(json, "rngCoordinator", contracts.rngCoordinator);
        vm.serializeAddress(json, "crossChainEscrow", contracts.crossChainEscrow);
        vm.serializeAddress(json, "datasetRegistry", contracts.datasetRegistry);

        if (contracts.mockPyth != address(0)) {
            vm.serializeAddress(json, "mockPyth", contracts.mockPyth);
        }
        if (contracts.mockEntropy != address(0)) {
            vm.serializeAddress(json, "mockEntropy", contracts.mockEntropy);
        }
        if (contracts.mockSelfHub != address(0)) {
            vm.serializeAddress(json, "mockSelfHub", contracts.mockSelfHub);
        }

        string memory finalJson = vm.serializeUint(json, "timestamp", block.timestamp);

        // Save to file
        // string memory folder = vm.envOr("FOLDER", "output"); 
        // string memory fileName = string.concat(folder, "/", chainId, ".json");
        // vm.writeJson(finalJson, fileName);

        // console.log("\n[INFO] Deployment info saved to:", fileName);
    }
}