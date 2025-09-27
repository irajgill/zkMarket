// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DataToken1155} from "../contracts/DataToken1155.sol";
import {PricingOracleAdapter} from "../contracts/PricingOracleAdapter.sol";
import {RNGCoordinator} from "../contracts/RNGCoordinator.sol";
import {DatasetRegistry} from "../contracts/DatasetRegistry.sol";
import {MockSelfHub} from "../contracts/mocks/MockSelfHub.sol";

contract SeedDemoScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load deployed contract addresses
        address dataTokenAddr = vm.envAddress("DATA_TOKEN_ADDRESS");
        address registryAddr = vm.envAddress("DATASET_REGISTRY_ADDRESS");
        address oracleAddr = vm.envAddress("PRICING_ORACLE_ADDRESS");
        address rngAddr = vm.envAddress("RNG_COORDINATOR_ADDRESS");
        address selfHubAddr = vm.envAddress("MOCK_SELF_HUB_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // Seed demo data
        seedMockData(dataTokenAddr, registryAddr, oracleAddr, rngAddr, selfHubAddr, deployer);

        vm.stopBroadcast();

        console.log("[SUCCESS] Demo data seeded successfully!");
    }

    function seedMockData(
        address dataTokenAddr,
        address registryAddr,
        address oracleAddr,
        address rngAddr,
        address selfHubAddr,
        address deployer
    ) internal {
        DataToken1155 dataToken = DataToken1155(dataTokenAddr);
        DatasetRegistry registry = DatasetRegistry(registryAddr);
        RNGCoordinator rng = RNGCoordinator(payable(rngAddr));
        MockSelfHub selfHub = MockSelfHub(selfHubAddr);

        // Create some test users
        address[] memory users = new address[](3);
        users[0] = address(0x1234567890123456789012345678901234567890);
        users[1] = address(0x2345678901234567890123456789012345678901);
        users[2] = address(0x3456789012345678901234567890123456789012);

        // Verify users in Self hub
        for (uint i = 0; i < users.length; i++) {
            selfHub.setVerified(users[i], true);
        }

        // Register sample datasets
        string[] memory metadataKeys = new string[](2);
        string[] memory metadataValues = new string[](2);
        metadataKeys[0] = "category";
        metadataKeys[1] = "format";

        // Dataset 1: Weather Data
        metadataValues[0] = "weather";
        metadataValues[1] = "json";
        bytes32 dataset1 = registry.registerDataset(
            "Global Weather Data 2024",
            "Comprehensive weather measurements from 1000+ stations worldwide",
            keccak256("weather-data-root"),
            "QmWeatherData123456789",
            "bafy2weather987654321",
            5242880, // 5MB
            metadataKeys,
            metadataValues
        );

        // Dataset 2: Financial Data
        metadataValues[0] = "finance";
        metadataValues[1] = "csv";
        bytes32 dataset2 = registry.registerDataset(
            "Crypto Market Data",
            "Real-time cryptocurrency trading data with order book snapshots",
            keccak256("crypto-data-root"),
            "QmCryptoData123456789",
            "bafy2crypto987654321",
            10485760, // 10MB
            metadataKeys,
            metadataValues
        );

        // Add some ETH to RNG coordinator for prizes
        rng.addToPrizePool{value: 1 ether}(dataset1);
        rng.addToPrizePool{value: 0.5 ether}(dataset2);
        rng.setMaxWinners(dataset1, 5);
        rng.setMaxWinners(dataset2, 3);

        console.log("[INFO] Sample datasets created:");
        console.log("  Dataset 1 ID:", vm.toString(dataset1));
        console.log("  Dataset 2 ID:", vm.toString(dataset2));
        console.log("[INFO] Prize pools funded with 1.5 ETH total");
    }
}