// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => Price) public prices;
    uint256 public updateFee = 0.001 ether;

    event PriceFeedUpdate(bytes32 indexed id, uint64 publishTime, int64 price, uint64 conf);

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        require(msg.value >= updateFee, "MockPyth: insufficient fee");

        // Mock: update BTC/USD price with some randomness
        bytes32 btcUsdId = 0xe62df6c8b4c85fe1b5a04b3a0e3bd6f7e3c7f6b8c4c85fe1b5a04b3a0e3bd6f7;

        prices[btcUsdId] = Price({
            price: int64(45000 * 1e8), // $45,000 with 8 decimals
            conf: uint64(100 * 1e8),   // $100 confidence interval
            expo: -8,
            publishTime: block.timestamp
        });

        emit PriceFeedUpdate(btcUsdId, uint64(block.timestamp), int64(45000 * 1e8), uint64(100 * 1e8));
    }

    function getPrice(bytes32 id) external view returns (Price memory) {
        return prices[id];
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        prices[id] = Price({
            price: price,
            conf: uint64(uint256(int256(price)) / 100), // 1% confidence
            expo: expo,
            publishTime: block.timestamp
        });
    }

    function setUpdateFee(uint256 _fee) external {
        updateFee = _fee;
    }
}