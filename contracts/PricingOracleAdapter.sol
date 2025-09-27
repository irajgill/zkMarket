// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PricingOracleAdapter is Pausable, Ownable, ReentrancyGuard {
    IPyth public immutable pyth;
    bytes32 public immutable priceId;        // e.g., BTC/USD or dataset pricing index
    uint32 public maxStaleness;             // seconds; gov-updatable
    uint256 public priceMultiplierBps;      // gov-updatable pricing curve
    uint256 public basePriceWei;            // base price in wei

    // Subscription tracking
    mapping(bytes32 => mapping(address => uint64)) public subscriptionExpiry; // unix seconds
    mapping(bytes32 => uint256) public datasetBasePrice; // base price per dataset
    mapping(address => uint256) public totalSpent; // track user spending

    // Circuit breaker parameters
    uint256 public minPrice;                // minimum acceptable price
    uint256 public maxPrice;                // maximum acceptable price
    uint256 public maxPriceDeviation;       // max % deviation from last price (in bps)
    uint256 public lastValidPrice;          // last known good price

    event PriceStale(uint64 publishTime, uint32 maxStaleness);
    event PriceAnomaly(uint256 currentPrice, uint256 expectedRange);
    event Subscribed(bytes32 indexed datasetId, address indexed subscriber, uint64 expiry, uint256 paidAmount);
    event Renewed(bytes32 indexed datasetId, address indexed subscriber, uint64 newExpiry, uint256 paidAmount);
    event PriceUpdated(bytes32 indexed priceId, int64 price, uint64 publishTime);
    event CircuitBreakerTriggered(string reason);

    error StalePriceData(uint64 publishTime);
    error PriceOutOfRange(uint256 price);
    error InsufficientPayment(uint256 required, uint256 provided);
    error SubscriptionExpired(uint64 expiry);

    constructor(
        IPyth _pyth, 
        bytes32 _priceId, 
        uint32 _maxStaleness,
        address _owner
    ) Ownable(_owner) {
        pyth = _pyth;
        priceId = _priceId;
        maxStaleness = _maxStaleness;
        priceMultiplierBps = 10_000; // 1x multiplier
        basePriceWei = 0.01 ether; // 0.01 ETH base price

        // Circuit breaker defaults
        minPrice = 0.001 ether;
        maxPrice = 10 ether;
        maxPriceDeviation = 5000; // 50%
        lastValidPrice = basePriceWei;
    }

    modifier withFreshPrice(bytes[] calldata updateData) {
        uint fee = pyth.getUpdateFee(updateData);
        require(msg.value >= fee, "PricingOracleAdapter: insufficient update fee");

        pyth.updatePriceFeeds{value: fee}(updateData);
        PythStructs.Price memory px = pyth.getPrice(priceId);

        // Check staleness
        if (block.timestamp - px.publishTime > maxStaleness) {
            emit PriceStale(uint64(px.publishTime), maxStaleness);
            revert StalePriceData(uint64(px.publishTime));
        }

        // Check price anomalies
        uint256 currentPrice = _toWei(px);
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            emit PriceAnomaly(currentPrice, minPrice);
            revert PriceOutOfRange(currentPrice);
        }

        // Check deviation from last valid price
        if (lastValidPrice > 0) {
            uint256 deviation = currentPrice > lastValidPrice 
                ? ((currentPrice - lastValidPrice) * 10000) / lastValidPrice
                : ((lastValidPrice - currentPrice) * 10000) / lastValidPrice;

            if (deviation > maxPriceDeviation) {
                emit CircuitBreakerTriggered("Price deviation exceeded");
                _pause();
                revert PriceOutOfRange(currentPrice);
            }
        }

        lastValidPrice = currentPrice;
        emit PriceUpdated(priceId, px.price, uint64(px.publishTime));
        _;
    }

    function getQuote(
        bytes32 datasetId,
        uint32 duration,
        bytes[] calldata updateData
    ) external payable withFreshPrice(updateData) whenNotPaused returns (uint256 quoteWei) {
        PythStructs.Price memory px = pyth.getPrice(priceId);
        uint256 basePrice = datasetBasePrice[datasetId];
        if (basePrice == 0) {
            basePrice = basePriceWei;
        }

        // Calculate dynamic price based on Pyth feed and duration
        uint256 priceFactor = _toWei(px) * priceMultiplierBps / 10_000;
        quoteWei = (basePrice + priceFactor) * duration / (24 * 3600); // per second pricing

        return quoteWei;
    }

    function subscribe(
        bytes32 datasetId, 
        uint32 durationSeconds, 
        bytes[] calldata updateData
    ) external payable withFreshPrice(updateData) whenNotPaused nonReentrant {
        uint256 quote = this.getQuote{value: 0}(datasetId, durationSeconds, new bytes[](0));
        uint256 updateFee = pyth.getUpdateFee(updateData);
        uint256 totalRequired = quote + updateFee;

        if (msg.value < totalRequired) {
            revert InsufficientPayment(totalRequired, msg.value);
        }

        uint64 newExpiry = uint64(block.timestamp) + durationSeconds;
        subscriptionExpiry[datasetId][msg.sender] = newExpiry;
        totalSpent[msg.sender] += quote;

        emit Subscribed(datasetId, msg.sender, newExpiry, quote);

        // Refund excess payment
        if (msg.value > totalRequired) {
            payable(msg.sender).transfer(msg.value - totalRequired);
        }
    }

    function renew(
        bytes32 datasetId, 
        uint32 extraSeconds, 
        bytes[] calldata updateData
    ) external payable withFreshPrice(updateData) whenNotPaused nonReentrant {
        uint64 currentExpiry = subscriptionExpiry[datasetId][msg.sender];
        uint64 baseTime = currentExpiry > block.timestamp ? currentExpiry : uint64(block.timestamp);

        uint256 quote = this.getQuote{value: 0}(datasetId, extraSeconds, new bytes[](0));
        uint256 updateFee = pyth.getUpdateFee(updateData);
        uint256 totalRequired = quote + updateFee;

        if (msg.value < totalRequired) {
            revert InsufficientPayment(totalRequired, msg.value);
        }

        uint64 newExpiry = baseTime + extraSeconds;
        subscriptionExpiry[datasetId][msg.sender] = newExpiry;
        totalSpent[msg.sender] += quote;

        emit Renewed(datasetId, msg.sender, newExpiry, quote);

        // Refund excess payment
        if (msg.value > totalRequired) {
            payable(msg.sender).transfer(msg.value - totalRequired);
        }
    }

    function isSubscriptionActive(bytes32 datasetId, address user) external view returns (bool) {
        return subscriptionExpiry[datasetId][user] > block.timestamp;
    }

    function getSubscriptionExpiry(bytes32 datasetId, address user) external view returns (uint64) {
        return subscriptionExpiry[datasetId][user];
    }

    function getCurrentPrice(bytes[] calldata updateData) 
        external 
        payable 
        withFreshPrice(updateData) 
        returns (int64 price, int32 expo, uint64 publishTime) 
    {
        PythStructs.Price memory px = pyth.getPrice(priceId);
        return (px.price, px.expo, uint64(px.publishTime));
    }

    // Admin functions
    function setMaxStaleness(uint32 _maxStaleness) external onlyOwner {
        maxStaleness = _maxStaleness;
    }

    function setPriceMultiplier(uint256 _priceMultiplierBps) external onlyOwner {
        require(_priceMultiplierBps <= 50_000, "PricingOracleAdapter: multiplier too high"); // max 5x
        priceMultiplierBps = _priceMultiplierBps;
    }

    function setDatasetBasePrice(bytes32 datasetId, uint256 priceWei) external onlyOwner {
        datasetBasePrice[datasetId] = priceWei;
    }

    function setCircuitBreaker(
        uint256 _minPrice,
        uint256 _maxPrice,
        uint256 _maxPriceDeviation
    ) external onlyOwner {
        minPrice = _minPrice;
        maxPrice = _maxPrice;
        maxPriceDeviation = _maxPriceDeviation;
    }

    function emergencyPause() external onlyOwner {
        _pause();
        emit CircuitBreakerTriggered("Emergency pause activated");
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }

    function _toWei(PythStructs.Price memory px) internal pure returns (uint256) {
        require(px.price > 0, "PricingOracleAdapter: negative price");

        // Convert Pyth price to wei
        // Pyth prices are typically in the format: price * 10^expo
        // We need to normalize this to wei (18 decimals)

        uint256 absPrice = uint256(uint64(px.price));

        if (px.expo >= 0) {
            return absPrice * (10 ** uint32(px.expo));
        } else {
            uint32 negativeExpo = uint32(-px.expo);
            if (negativeExpo >= 18) {
                return absPrice / (10 ** (negativeExpo - 18));
            } else {
                return absPrice * (10 ** (18 - negativeExpo));
            }
        }
    }

    receive() external payable {}
}