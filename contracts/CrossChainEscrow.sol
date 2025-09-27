// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CrossChainEscrow is EIP712, ReentrancyGuard, Pausable, Ownable {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    struct Escrow {
        address asset;           // Token address (address(0) for ETH)
        address from;            // Maker/sender
        address to;              // Taker/recipient
        uint256 amount;          // Amount to be transferred
        bytes32 secretHash;      // Hash of the secret
        uint64 timelock;         // Expiry timestamp
        address resolver;        // 1inch resolver address
        uint256 chainId;         // Target chain ID
        bool claimed;            // Whether funds were claimed
        bool refunded;           // Whether funds were refunded
        uint256 createdAt;       // Creation timestamp
    }

    // Storage
    mapping(bytes32 => Escrow) public escrows;           // escrowId => Escrow
    mapping(bytes32 => bool) public usedNonces;          // Replay protection
    mapping(address => bool) public authorizedResolvers; // Authorized 1inch resolvers
    mapping(address => uint256) public resolverBonds;    // Resolver security bonds

    // Configuration
    uint256 public minTimelock;      // Minimum timelock duration
    uint256 public maxTimelock;      // Maximum timelock duration
    uint256 public resolverBond;     // Required bond for resolvers
    uint256 public serviceFee;       // Service fee in basis points (10000 = 100%)

    // EIP-712 type hashes
    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "Intent(address from,address to,address asset,uint256 amount,bytes32 secretHash,uint64 timelock,uint256 chainId,uint256 nonce,uint256 deadline)"
    );

    bytes32 public constant RESOLVER_AUTHORIZATION_TYPEHASH = keccak256(
        "ResolverAuthorization(address resolver,uint256 nonce,uint256 deadline)"
    );

    // Events
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed from,
        address indexed to,
        address asset,
        uint256 amount,
        bytes32 secretHash,
        uint64 timelock
    );

    event EscrowClaimed(
        bytes32 indexed escrowId,
        address indexed claimer,
        bytes32 secret
    );

    event EscrowRefunded(
        bytes32 indexed escrowId,
        address indexed refunder
    );

    event ResolverAuthorized(address indexed resolver, uint256 bond);
    event ResolverDeauthorized(address indexed resolver, uint256 bondReturned);

    // Errors
    error InvalidTimelock(uint64 timelock);
    error InvalidAmount(uint256 amount);
    error EscrowNotFound(bytes32 escrowId);
    error EscrowAlreadySettled(bytes32 escrowId);
    error InvalidSecret(bytes32 secret, bytes32 expectedHash);
    error TimelockNotExpired(uint64 timelock);
    error Unauthorized(address caller);
    error InvalidSignature();
    error ReplayAttack(bytes32 nonce);
    error InsufficientBond(uint256 required, uint256 provided);

    constructor(
        address _owner
    ) EIP712("CrossChainEscrow", "1") Ownable(_owner) {
        minTimelock = 1 hours;      // Minimum 1 hour
        maxTimelock = 7 days;       // Maximum 7 days
        resolverBond = 1 ether;     // 1 ETH bond
        serviceFee = 30;            // 0.3% service fee
    }

    function createEscrow(
        bytes calldata encodedIntent,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (bytes32 escrowId) {
        // Decode intent
        (
            address from,
            address to,
            address asset,
            uint256 amount,
            bytes32 secretHash,
            uint64 timelock,
            uint256 chainId,
            uint256 nonce,
            uint256 deadline
        ) = abi.decode(
            encodedIntent,
            (address, address, address, uint256, bytes32, uint64, uint256, uint256, uint256)
        );

        // Validate deadline
        require(block.timestamp <= deadline, "CrossChainEscrow: intent expired");

        // Validate timelock
        if (timelock < block.timestamp + minTimelock || timelock > block.timestamp + maxTimelock) {
            revert InvalidTimelock(timelock);
        }

        // Validate amount
        if (amount == 0) {
            revert InvalidAmount(amount);
        }

        // Verify signature
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            INTENT_TYPEHASH,
            from,
            to,
            asset,
            amount,
            secretHash,
            timelock,
            chainId,
            nonce,
            deadline
        )));

        address signer = digest.recover(signature);
        if (signer != from) {
            revert InvalidSignature();
        }

        // Check replay protection
        bytes32 nonceKey = keccak256(abi.encode(from, nonce));
        if (usedNonces[nonceKey]) {
            revert ReplayAttack(nonceKey);
        }
        usedNonces[nonceKey] = true;

        // Generate escrow ID
        escrowId = keccak256(abi.encodePacked(
            digest,
            block.timestamp,
            block.number
        ));

        // Create escrow
        escrows[escrowId] = Escrow({
            asset: asset,
            from: from,
            to: to,
            amount: amount,
            secretHash: secretHash,
            timelock: timelock,
            resolver: msg.sender,
            chainId: chainId,
            claimed: false,
            refunded: false,
            createdAt: block.timestamp
        });

        // Handle asset transfer
        if (asset == address(0)) {
            // ETH transfer
            require(msg.value >= amount, "CrossChainEscrow: insufficient ETH");
            if (msg.value > amount) {
                // Refund excess
                payable(msg.sender).transfer(msg.value - amount);
            }
        } else {
            // ERC20 transfer
            IERC20(asset).safeTransferFrom(from, address(this), amount);
        }

        emit EscrowCreated(escrowId, from, to, asset, amount, secretHash, timelock);

        return escrowId;
    }

    function claimEscrow(
        bytes32 escrowId,
        bytes32 secret
    ) external whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        // Validate escrow exists
        if (escrow.from == address(0)) {
            revert EscrowNotFound(escrowId);
        }

        // Check if already settled
        if (escrow.claimed || escrow.refunded) {
            revert EscrowAlreadySettled(escrowId);
        }

        // Verify secret
        if (keccak256(abi.encodePacked(secret)) != escrow.secretHash) {
            revert InvalidSecret(secret, escrow.secretHash);
        }

        // Mark as claimed
        escrow.claimed = true;

        // Calculate service fee
        uint256 fee = 0;
        if (serviceFee > 0) {
            fee = (escrow.amount * serviceFee) / 10000;
        }

        uint256 transferAmount = escrow.amount - fee;

        // Transfer assets to recipient
        if (escrow.asset == address(0)) {
            // ETH transfer
            payable(escrow.to).transfer(transferAmount);
            if (fee > 0) {
                payable(owner()).transfer(fee);
            }
        } else {
            // ERC20 transfer
            IERC20(escrow.asset).safeTransfer(escrow.to, transferAmount);
            if (fee > 0) {
                IERC20(escrow.asset).safeTransfer(owner(), fee);
            }
        }

        emit EscrowClaimed(escrowId, msg.sender, secret);
    }

    function refundEscrow(
        bytes32 escrowId
    ) external whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        // Validate escrow exists
        if (escrow.from == address(0)) {
            revert EscrowNotFound(escrowId);
        }

        // Check if already settled
        if (escrow.claimed || escrow.refunded) {
            revert EscrowAlreadySettled(escrowId);
        }

        // Check timelock expiry
        if (block.timestamp <= escrow.timelock) {
            revert TimelockNotExpired(escrow.timelock);
        }

        // Only original sender or authorized resolver can refund
        if (msg.sender != escrow.from && !authorizedResolvers[msg.sender]) {
            revert Unauthorized(msg.sender);
        }

        // Mark as refunded
        escrow.refunded = true;

        // Refund assets to sender
        if (escrow.asset == address(0)) {
            // ETH refund
            payable(escrow.from).transfer(escrow.amount);
        } else {
            // ERC20 refund
            IERC20(escrow.asset).safeTransfer(escrow.from, escrow.amount);
        }

        emit EscrowRefunded(escrowId, msg.sender);
    }

    // Resolver management
    function authorizeResolver(
        address resolver,
        bytes calldata signature,
        uint256 nonce,
        uint256 deadline
    ) external payable {
        require(block.timestamp <= deadline, "CrossChainEscrow: authorization expired");
        require(msg.value >= resolverBond, "CrossChainEscrow: insufficient bond");

        // Verify signature from resolver
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            RESOLVER_AUTHORIZATION_TYPEHASH,
            resolver,
            nonce,
            deadline
        )));

        address signer = digest.recover(signature);
        require(signer == resolver, "CrossChainEscrow: invalid resolver signature");

        // Check replay protection
        bytes32 nonceKey = keccak256(abi.encode(resolver, nonce));
        require(!usedNonces[nonceKey], "CrossChainEscrow: nonce already used");
        usedNonces[nonceKey] = true;

        authorizedResolvers[resolver] = true;
        resolverBonds[resolver] = msg.value;

        // Refund excess
        if (msg.value > resolverBond) {
            payable(msg.sender).transfer(msg.value - resolverBond);
        }

        emit ResolverAuthorized(resolver, resolverBond);
    }

    function deauthorizeResolver(address resolver) external onlyOwner {
        require(authorizedResolvers[resolver], "CrossChainEscrow: resolver not authorized");

        authorizedResolvers[resolver] = false;
        uint256 bond = resolverBonds[resolver];
        resolverBonds[resolver] = 0;

        // Return bond
        payable(resolver).transfer(bond);

        emit ResolverDeauthorized(resolver, bond);
    }

    // View functions
    function getEscrow(bytes32 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    function isEscrowActive(bytes32 escrowId) external view returns (bool) {
        Escrow memory escrow = escrows[escrowId];
        return escrow.from != address(0) && !escrow.claimed && !escrow.refunded;
    }

    function isEscrowExpired(bytes32 escrowId) external view returns (bool) {
        Escrow memory escrow = escrows[escrowId];
        return block.timestamp > escrow.timelock;
    }

    // Admin functions
    function setTimelockLimits(uint256 _minTimelock, uint256 _maxTimelock) external onlyOwner {
        require(_minTimelock < _maxTimelock, "CrossChainEscrow: invalid timelock limits");
        minTimelock = _minTimelock;
        maxTimelock = _maxTimelock;
    }

    function setResolverBond(uint256 _resolverBond) external onlyOwner {
        resolverBond = _resolverBond;
    }

    function setServiceFee(uint256 _serviceFee) external onlyOwner {
        require(_serviceFee <= 1000, "CrossChainEscrow: fee too high"); // Max 10%
        serviceFee = _serviceFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address asset) external onlyOwner {
        if (asset == address(0)) {
            payable(owner()).transfer(address(this).balance);
        } else {
            IERC20 token = IERC20(asset);
            token.safeTransfer(owner(), token.balanceOf(address(this)));
        }
    }

    receive() external payable {}
}