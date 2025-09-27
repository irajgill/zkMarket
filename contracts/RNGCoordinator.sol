// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Simplified Pyth Entropy interface for demo
interface IEntropy {
    function getDefaultProvider() external view returns (address);
    function getFee(address provider) external view returns (uint128);
    function request(address provider, bytes32 userCommitment) external payable returns (uint64);
    function reveal(address provider, uint64 sequenceNumber, bytes32 userRevelation) external;
}

// Mock entropy consumer base for demonstration
abstract contract EntropyConsumer {
    IEntropy public entropy;

    constructor(address _entropy) {
        entropy = IEntropy(_entropy);
    }

    function entropyCallback(
        uint64 sequenceNumber, 
        address provider, 
        bytes32 randomNumber
    ) internal virtual;
}

contract RNGCoordinator is EntropyConsumer, Ownable, ReentrancyGuard, Pausable {
    struct LotteryRequest {
        bytes32 datasetId;
        address requester;
        uint256 timestamp;
        bytes32 userCommitment;
        bool fulfilled;
        bytes32 randomResult;
    }

    mapping(uint64 => LotteryRequest) public lotteryRequests;
    mapping(bytes32 => uint64[]) public datasetLotteries; // datasetId => sequence numbers
    mapping(address => uint64[]) public userRequests; // user => sequence numbers

    // Lottery configuration
    uint256 public lotteryFee;                // Additional fee for lottery service
    uint256 public maxRequestsPerDataset;     // Rate limiting
    uint256 public requestCooldown;           // Cooldown between requests
    mapping(address => uint256) public lastRequestTime;

    // Prize configuration
    mapping(bytes32 => uint256) public datasetPrizePool; // ETH prize pool per dataset
    mapping(bytes32 => uint256) public maxWinners;        // Max winners per dataset
    mapping(bytes32 => address[]) public datasetWinners;  // Track winners

    event LotteryRequested(
        bytes32 indexed datasetId, 
        address indexed user, 
        uint64 sequenceNumber,
        bytes32 userCommitment
    );

    event LotteryFulfilled(
        bytes32 indexed datasetId, 
        address indexed user, 
        uint64 sequenceNumber, 
        bytes32 randomNumber,
        bool won,
        uint256 prize
    );

    event PrizePoolUpdated(bytes32 indexed datasetId, uint256 newAmount);
    event WinnerSelected(bytes32 indexed datasetId, address indexed winner, uint256 prize);

    error InsufficientFee(uint256 required, uint256 provided);
    error RequestTooSoon(uint256 timeRemaining);
    error RequestNotFound(uint64 sequenceNumber);
    error RequestAlreadyFulfilled(uint64 sequenceNumber);
    error TooManyRequests(bytes32 datasetId);

    constructor(
        address _entropy,
        address _owner
    ) EntropyConsumer(_entropy) Ownable(_owner) {
        lotteryFee = 0.001 ether; // 0.001 ETH service fee
        maxRequestsPerDataset = 100;
        requestCooldown = 300; // 5 minutes
    }

    function requestPremiumSlot(
        bytes32 datasetId, 
        bytes32 userRand
    ) external payable whenNotPaused nonReentrant returns (uint64 sequenceNumber) {
        // Check cooldown
        if (block.timestamp < lastRequestTime[msg.sender] + requestCooldown) {
            revert RequestTooSoon(
                lastRequestTime[msg.sender] + requestCooldown - block.timestamp
            );
        }

        // Check request limit per dataset
        if (datasetLotteries[datasetId].length >= maxRequestsPerDataset) {
            revert TooManyRequests(datasetId);
        }

        address provider = entropy.getDefaultProvider();
        uint128 entropyFee = entropy.getFee(provider);
        uint256 totalFee = uint256(entropyFee) + lotteryFee;

        if (msg.value < totalFee) {
            revert InsufficientFee(totalFee, msg.value);
        }

        // Create user commitment from their input and some entropy
        bytes32 commitment = keccak256(abi.encodePacked(
            userRand, 
            msg.sender, 
            block.timestamp, 
            block.prevrandao
        ));

        // Request randomness from Pyth Entropy
        sequenceNumber = entropy.request{value: entropyFee}(provider, commitment);

        // Store request
        lotteryRequests[sequenceNumber] = LotteryRequest({
            datasetId: datasetId,
            requester: msg.sender,
            timestamp: block.timestamp,
            userCommitment: commitment,
            fulfilled: false,
            randomResult: bytes32(0)
        });

        datasetLotteries[datasetId].push(sequenceNumber);
        userRequests[msg.sender].push(sequenceNumber);
        lastRequestTime[msg.sender] = block.timestamp;

        emit LotteryRequested(datasetId, msg.sender, sequenceNumber, commitment);

        // Refund excess payment
        if (msg.value > totalFee) {
            payable(msg.sender).transfer(msg.value - totalFee);
        }

        return sequenceNumber;
    }

    // Pyth Entropy callback - called when randomness is available
    function entropyCallback(
        uint64 sequenceNumber, 
        address /*provider*/, 
        bytes32 randomNumber
    ) internal override {
        LotteryRequest storage request = lotteryRequests[sequenceNumber];

        if (request.requester == address(0)) {
            return; // Invalid request
        }

        if (request.fulfilled) {
            return; // Already fulfilled
        }

        request.fulfilled = true;
        request.randomResult = randomNumber;

        // Determine if user won and calculate prize
        (bool won, uint256 prize) = _determinePrize(request.datasetId, randomNumber);

        if (won && prize > 0) {
            datasetWinners[request.datasetId].push(request.requester);
            datasetPrizePool[request.datasetId] -= prize;

            // Transfer prize
            payable(request.requester).transfer(prize);

            emit WinnerSelected(request.datasetId, request.requester, prize);
        }

        emit LotteryFulfilled(
            request.datasetId, 
            request.requester, 
            sequenceNumber, 
            randomNumber,
            won,
            prize
        );
    }

    function _determinePrize(
        bytes32 datasetId, 
        bytes32 randomNumber
    ) internal view returns (bool won, uint256 prize) {
        uint256 prizePool = datasetPrizePool[datasetId];
        uint256 maxWins = maxWinners[datasetId];
        uint256 currentWinners = datasetWinners[datasetId].length;

        if (prizePool == 0 || currentWinners >= maxWins) {
            return (false, 0);
        }

        // Use random number to determine win probability and prize amount
        uint256 randValue = uint256(randomNumber);

        // 10% win probability for demonstration
        bool didWin = (randValue % 100) < 10;

        if (didWin) {
            // Prize is 1-10% of remaining pool
            uint256 prizePercent = (randValue % 10) + 1; // 1-10%
            prize = (prizePool * prizePercent) / 100;

            // Ensure we don't exceed pool
            if (prize > prizePool) {
                prize = prizePool;
            }

            return (true, prize);
        }

        return (false, 0);
    }

    // View functions
    function getRequestStatus(uint64 sequenceNumber) 
        external 
        view 
        returns (
            bytes32 datasetId,
            address requester,
            bool fulfilled,
            bytes32 randomResult
        ) 
    {
        LotteryRequest memory request = lotteryRequests[sequenceNumber];
        return (
            request.datasetId,
            request.requester,
            request.fulfilled,
            request.randomResult
        );
    }

    function getDatasetLotteries(bytes32 datasetId) external view returns (uint64[] memory) {
        return datasetLotteries[datasetId];
    }

    function getUserRequests(address user) external view returns (uint64[] memory) {
        return userRequests[user];
    }

    function getDatasetWinners(bytes32 datasetId) external view returns (address[] memory) {
        return datasetWinners[datasetId];
    }

    function getDatasetStats(bytes32 datasetId) 
        external 
        view 
        returns (
            uint256 prizePool,
            uint256 totalRequests,
            uint256 winners,
            uint256 maxWinnerLimit
        ) 
    {
        return (
            datasetPrizePool[datasetId],
            datasetLotteries[datasetId].length,
            datasetWinners[datasetId].length,
            maxWinners[datasetId]
        );
    }

    // Admin functions
    function addToPrizePool(bytes32 datasetId) external payable onlyOwner {
        datasetPrizePool[datasetId] += msg.value;
        emit PrizePoolUpdated(datasetId, datasetPrizePool[datasetId]);
    }

    function setMaxWinners(bytes32 datasetId, uint256 _maxWinners) external onlyOwner {
        maxWinners[datasetId] = _maxWinners;
    }

    function setLotteryFee(uint256 _lotteryFee) external onlyOwner {
        lotteryFee = _lotteryFee;
    }

    function setRequestCooldown(uint256 _cooldown) external onlyOwner {
        requestCooldown = _cooldown;
    }

    function setMaxRequestsPerDataset(uint256 _maxRequests) external onlyOwner {
        maxRequestsPerDataset = _maxRequests;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    // Manual fulfillment for testing/emergency cases
    function manualFulfill(uint64 sequenceNumber, bytes32 randomNumber) external onlyOwner {
        entropyCallback(sequenceNumber, address(0), randomNumber);
    }

    receive() external payable {
        // Accept ETH for prize pools
    }
}