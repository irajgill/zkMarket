// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract DatasetRegistry is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant PDP_VERIFIER_ROLE = keccak256("PDP_VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum PDPStatus {
        Unknown,    // 0 - Not verified
        Green,      // 1 - Verified and healthy
        Amber,      // 2 - Some issues detected
        Red         // 3 - Critical issues or failed verification
    }

    struct DatasetInfo {
        string name;
        string description;
        address owner;
        bytes32 merkleRoot;        // Merkle root of dataset chunks
        string lighthouseCID;      // Lighthouse/IPFS CID
        string synapsePieceCID;    // Synapse/Filecoin piece CID
        uint256 size;              // Dataset size in bytes
        uint256 createdAt;
        uint256 updatedAt;
        PDPStatus pdpStatus;
        uint256 lastPDPCheck;
        bool isActive;
        mapping(string => string) metadata; // Additional key-value metadata
    }

    struct DatasetSummary {
        string name;
        string description;
        address owner;
        bytes32 merkleRoot;
        string lighthouseCID;
        string synapsePieceCID;
        uint256 size;
        uint256 createdAt;
        uint256 updatedAt;
        PDPStatus pdpStatus;
        uint256 lastPDPCheck;
        bool isActive;
    }

    // Storage
    mapping(bytes32 => DatasetInfo) private datasets;
    mapping(address => bytes32[]) private ownerDatasets;
    bytes32[] private allDatasets;

    // PDP tracking
    mapping(bytes32 => uint256) public pdpCheckCount;
    mapping(bytes32 => mapping(uint256 => PDPStatus)) public pdpHistory;

    // Statistics
    uint256 public totalDatasets;
    uint256 public activeDatasets;
    mapping(PDPStatus => uint256) public statusCounts;

    // Events
    event DatasetRegistered(
        bytes32 indexed datasetId,
        address indexed owner,
        string name,
        string lighthouseCID,
        string synapsePieceCID
    );

    event DatasetUpdated(
        bytes32 indexed datasetId,
        bytes32 newMerkleRoot,
        string newLighthouseCID,
        string newSynapsePieceCID
    );

    event PDPStatusUpdated(
        bytes32 indexed datasetId,
        PDPStatus oldStatus,
        PDPStatus newStatus,
        address indexed verifier
    );

    event DatasetDeactivated(bytes32 indexed datasetId, address indexed owner);
    event DatasetReactivated(bytes32 indexed datasetId, address indexed owner);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CURATOR_ROLE, msg.sender);
        _grantRole(PDP_VERIFIER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    function registerDataset(
        string calldata name,
        string calldata description,
        bytes32 merkleRoot,
        string calldata lighthouseCID,
        string calldata synapsePieceCID,
        uint256 size,
        string[] calldata metadataKeys,
        string[] calldata metadataValues
    ) external whenNotPaused nonReentrant returns (bytes32 datasetId) {
        require(bytes(name).length > 0, "DatasetRegistry: name required");
        require(bytes(lighthouseCID).length > 0, "DatasetRegistry: lighthouse CID required");
        require(size > 0, "DatasetRegistry: size must be positive");
        require(metadataKeys.length == metadataValues.length, "DatasetRegistry: metadata mismatch");

        // Generate deterministic dataset ID
        datasetId = keccak256(
            abi.encodePacked(
                msg.sender,
                name,
                merkleRoot,
                lighthouseCID,
                block.timestamp
            )
        );

        // Ensure dataset doesn't exist
        require(datasets[datasetId].owner == address(0), "DatasetRegistry: dataset already exists");

        // Create dataset
        DatasetInfo storage dataset = datasets[datasetId];
        dataset.name = name;
        dataset.description = description;
        dataset.owner = msg.sender;
        dataset.merkleRoot = merkleRoot;
        dataset.lighthouseCID = lighthouseCID;
        dataset.synapsePieceCID = synapsePieceCID;
        dataset.size = size;
        dataset.createdAt = block.timestamp;
        dataset.updatedAt = block.timestamp;
        dataset.pdpStatus = PDPStatus.Unknown;
        dataset.lastPDPCheck = 0;
        dataset.isActive = true;

        // Store metadata
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            dataset.metadata[metadataKeys[i]] = metadataValues[i];
        }

        // Update indexes
        ownerDatasets[msg.sender].push(datasetId);
        allDatasets.push(datasetId);

        // Update statistics
        totalDatasets++;
        activeDatasets++;
        statusCounts[PDPStatus.Unknown]++;

        emit DatasetRegistered(datasetId, msg.sender, name, lighthouseCID, synapsePieceCID);

        return datasetId;
    }

    function updateDataset(
        bytes32 datasetId,
        bytes32 newMerkleRoot,
        string calldata newLighthouseCID,
        string calldata newSynapsePieceCID,
        string[] calldata metadataKeys,
        string[] calldata metadataValues
    ) external whenNotPaused {
        DatasetInfo storage dataset = datasets[datasetId];
        require(dataset.owner == msg.sender, "DatasetRegistry: not owner");
        require(dataset.isActive, "DatasetRegistry: dataset not active");
        require(metadataKeys.length == metadataValues.length, "DatasetRegistry: metadata mismatch");

        dataset.merkleRoot = newMerkleRoot;
        dataset.lighthouseCID = newLighthouseCID;
        dataset.synapsePieceCID = newSynapsePieceCID;
        dataset.updatedAt = block.timestamp;

        // Update metadata
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            dataset.metadata[metadataKeys[i]] = metadataValues[i];
        }

        // Reset PDP status on updates
        PDPStatus oldStatus = dataset.pdpStatus;
        dataset.pdpStatus = PDPStatus.Unknown;

        // Update status counts
        if (oldStatus != PDPStatus.Unknown) {
            statusCounts[oldStatus]--;
            statusCounts[PDPStatus.Unknown]++;
        }

        emit DatasetUpdated(datasetId, newMerkleRoot, newLighthouseCID, newSynapsePieceCID);
    }

    // Public/external entrypoint delegates to internal helper
    function updatePDPStatus(
        bytes32 datasetId,
        PDPStatus newStatus
    ) external onlyRole(PDP_VERIFIER_ROLE) {
        _updatePDPStatus(datasetId, newStatus);
    }

    function deactivateDataset(bytes32 datasetId) external {
        DatasetInfo storage dataset = datasets[datasetId];
        require(
            dataset.owner == msg.sender || hasRole(CURATOR_ROLE, msg.sender),
            "DatasetRegistry: unauthorized"
        );
        require(dataset.isActive, "DatasetRegistry: already inactive");

        dataset.isActive = false;
        activeDatasets--;

        emit DatasetDeactivated(datasetId, dataset.owner);
    }

    function reactivateDataset(bytes32 datasetId) external {
        DatasetInfo storage dataset = datasets[datasetId];
        require(dataset.owner == msg.sender, "DatasetRegistry: not owner");
        require(!dataset.isActive, "DatasetRegistry: already active");

        dataset.isActive = true;
        activeDatasets++;

        emit DatasetReactivated(datasetId, dataset.owner);
    }

    // View functions
    function getDataset(bytes32 datasetId) external view returns (DatasetSummary memory) {
        DatasetInfo storage dataset = datasets[datasetId];
        require(dataset.owner != address(0), "DatasetRegistry: dataset not found");

        return DatasetSummary({
            name: dataset.name,
            description: dataset.description,
            owner: dataset.owner,
            merkleRoot: dataset.merkleRoot,
            lighthouseCID: dataset.lighthouseCID,
            synapsePieceCID: dataset.synapsePieceCID,
            size: dataset.size,
            createdAt: dataset.createdAt,
            updatedAt: dataset.updatedAt,
            pdpStatus: dataset.pdpStatus,
            lastPDPCheck: dataset.lastPDPCheck,
            isActive: dataset.isActive
        });
    }

    function getDatasetMetadata(bytes32 datasetId, string calldata key)
        external
        view
        returns (string memory)
    {
        require(datasets[datasetId].owner != address(0), "DatasetRegistry: dataset not found");
        return datasets[datasetId].metadata[key];
    }

    function getOwnerDatasets(address owner) external view returns (bytes32[] memory) {
        return ownerDatasets[owner];
    }

    function getAllDatasets() external view returns (bytes32[] memory) {
        return allDatasets;
    }

    function getActiveDatasets() external view returns (bytes32[] memory) {
        bytes32[] memory active = new bytes32[](activeDatasets);
        uint256 activeIndex = 0;

        for (uint256 i = 0; i < allDatasets.length; i++) {
            if (datasets[allDatasets[i]].isActive) {
                active[activeIndex] = allDatasets[i];
                activeIndex++;
            }
        }

        return active;
    }

    function getDatasetsByStatus(PDPStatus status) external view returns (bytes32[] memory) {
        bytes32[] memory result = new bytes32[](statusCounts[status]);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < allDatasets.length; i++) {
            if (datasets[allDatasets[i]].pdpStatus == status) {
                result[resultIndex] = allDatasets[i];
                resultIndex++;
            }
        }

        return result;
    }

    function getPDPHistory(bytes32 datasetId)
        external
        view
        returns (PDPStatus[] memory)
    {
        uint256 checkCount = pdpCheckCount[datasetId];
        PDPStatus[] memory history = new PDPStatus[](checkCount);

        for (uint256 i = 0; i < checkCount; i++) {
            history[i] = pdpHistory[datasetId][i];
        }

        return history;
    }

    function getStats()
        external
        view
        returns (
            uint256 total,
            uint256 active,
            uint256 unknown,
            uint256 green,
            uint256 amber,
            uint256 red
        )
    {
        return (
            totalDatasets,
            activeDatasets,
            statusCounts[PDPStatus.Unknown],
            statusCounts[PDPStatus.Green],
            statusCounts[PDPStatus.Amber],
            statusCounts[PDPStatus.Red]
        );
    }

    // Batch updates now call the internal helper to avoid external self-calls in a loop
    function batchUpdatePDPStatus(
        bytes32[] calldata datasetIds,
        PDPStatus[] calldata statuses
    ) external onlyRole(PDP_VERIFIER_ROLE) {
        require(datasetIds.length == statuses.length, "DatasetRegistry: array length mismatch");

        for (uint256 i = 0; i < datasetIds.length; i++) {
            _updatePDPStatus(datasetIds[i], statuses[i]);
        }
    }

    // Internal helper containing the shared state-update logic
    function _updatePDPStatus(bytes32 datasetId, PDPStatus newStatus) internal {
        DatasetInfo storage dataset = datasets[datasetId];
        require(dataset.owner != address(0), "DatasetRegistry: dataset not found");

        PDPStatus oldStatus = dataset.pdpStatus;
        dataset.pdpStatus = newStatus;
        dataset.lastPDPCheck = block.timestamp;

        // Record in history
        uint256 checkNumber = pdpCheckCount[datasetId];
        pdpHistory[datasetId][checkNumber] = newStatus;
        pdpCheckCount[datasetId]++;

        // Update status counts
        statusCounts[oldStatus]--;
        statusCounts[newStatus]++;

        emit PDPStatusUpdated(datasetId, oldStatus, newStatus, msg.sender);
    }

    // Admin functions
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
