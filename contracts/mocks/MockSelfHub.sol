// SPDX-License-Identifier: MIT  
pragma solidity ^0.8.24;

contract MockSelfHub {
    mapping(address => bool) public verifiedUsers;
    mapping(bytes => bool) public usedProofs;

    event ProofVerified(address indexed user, bytes proof);

    function verifySelfProof(
        bytes calldata proof,
        bytes calldata userData
    ) external returns (bool) {
        // Mock verification - in production this would verify ZK proofs
        require(!usedProofs[proof], "MockSelfHub: proof already used");

        usedProofs[proof] = true;
        verifiedUsers[msg.sender] = true;

        emit ProofVerified(msg.sender, proof);

        // In real implementation, this would trigger the callback on the calling contract
        // For demo purposes, we'll just return true
        return true;
    }

    function isVerified(address user) external view returns (bool) {
        return verifiedUsers[user];
    }

    function setVerified(address user, bool verified) external {
        verifiedUsers[user] = verified;
    }

    function mockVerify(address user) external {
        verifiedUsers[user] = true;
        emit ProofVerified(user, abi.encode("mock_proof", block.timestamp));
    }
}