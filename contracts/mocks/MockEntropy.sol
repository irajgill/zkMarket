// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockEntropy {
    address public defaultProvider;
    uint128 public fee = 0.001 ether;

    mapping(uint64 => bool) public fulfilled;
    uint64 public nextSequenceNumber = 1;

    event RandomnessRequested(uint64 sequenceNumber, address provider, bytes32 userCommitment);
    event RandomnessFulfilled(uint64 sequenceNumber, bytes32 randomness);

    constructor() {
        defaultProvider = address(this);
    }

    function getDefaultProvider() external view returns (address) {
        return defaultProvider;
    }

    function getFee(address) external view returns (uint128) {
        return fee;
    }

    function request(address provider, bytes32 userCommitment) 
        external 
        payable 
        returns (uint64 sequenceNumber) 
    {
        require(msg.value >= fee, "MockEntropy: insufficient fee");

        sequenceNumber = nextSequenceNumber++;

        emit RandomnessRequested(sequenceNumber, provider, userCommitment);

        // Auto-fulfill with mock randomness (in real implementation, this would be called by the oracle)
        bytes32 mockRandomness = keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            userCommitment,
            sequenceNumber
        ));

        _fulfill(sequenceNumber, mockRandomness);

        return sequenceNumber;
    }

    function _fulfill(uint64 sequenceNumber, bytes32 randomness) internal {
        fulfilled[sequenceNumber] = true;

        // Call the callback on the requesting contract
        (bool success,) = msg.sender.call(
            abi.encodeWithSignature(
                "entropyCallback(uint64,address,bytes32)", 
                sequenceNumber, 
                defaultProvider, 
                randomness
            )
        );

        if (success) {
            emit RandomnessFulfilled(sequenceNumber, randomness);
        }
    }

    function manualFulfill(uint64 sequenceNumber, bytes32 randomness, address target) external {
        fulfilled[sequenceNumber] = true;

        (bool success,) = target.call(
            abi.encodeWithSignature(
                "entropyCallback(uint64,address,bytes32)", 
                sequenceNumber, 
                defaultProvider, 
                randomness
            )
        );

        if (success) {
            emit RandomnessFulfilled(sequenceNumber, randomness);
        }
    }

    function setFee(uint128 _fee) external {
        fee = _fee;
    }
}