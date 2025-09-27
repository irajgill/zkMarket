// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";


interface ISelfVerificationRoot {
    struct GenericDiscloseOutputV2 {
        address wallet;
        uint64 validUntil;
        uint64 issuedAt;
        bytes32 scope;
    }

    function verifySelfProof(
        bytes calldata proof,
        bytes calldata userData
    ) external returns (bool);
}

// Simplified Self integration for demo purposes
abstract contract SelfVerificationRoot {
    ISelfVerificationRoot public selfHub;
    string public scopeSeed;

    function __SelfVerificationRoot_init(
        address hubV2, 
        string memory _scopeSeed
    ) internal {
        selfHub = ISelfVerificationRoot(hubV2);
        scopeSeed = _scopeSeed;
    }

    function customVerificationHook(
        ISelfVerificationRoot.GenericDiscloseOutputV2 memory output,
        bytes memory userData
    ) internal virtual;

    function verifySelfProof(
        bytes calldata proof,
        bytes calldata userData
    ) external returns (bool) {
        bool success = selfHub.verifySelfProof(proof, userData);
        if (success) {
            // Mock output for demo - in real implementation this comes from the hub
            ISelfVerificationRoot.GenericDiscloseOutputV2 memory output = 
                ISelfVerificationRoot.GenericDiscloseOutputV2({
                    wallet: msg.sender,
                    validUntil: uint64(block.timestamp + 30 days),
                    issuedAt: uint64(block.timestamp),
                    scope: keccak256(abi.encodePacked(scopeSeed, msg.sender))
                });
            customVerificationHook(output, userData);
        }
        return success;
    }
}

contract DataToken1155 is
    ERC1155Upgradeable, 
    EIP712Upgradeable, 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    SelfVerificationRoot
{
    using ECDSA for bytes32;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    // Self verification storage
    struct ZkPass { 
        uint64 validUntil; 
        uint64 issuedAt; 
        uint32 version; 
    }

    mapping(address => ZkPass) public zkPass;
    mapping(address => bool) public denylist;

    // Dataset gating (for Lighthouse custom-contract checks)
    mapping(bytes32 => mapping(address => bool)) public datasetSubscriber;

    // ERC1155 Permit (EIP-712-based, compatible with EIP-7604 draft)
    mapping(address => uint256) public nonces;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)");

    event ZkPassIssued(address indexed user, uint64 validUntil);
    event DatasetAccessGranted(bytes32 indexed datasetId, address indexed user);
    event UserDenylisted(address indexed user, bool denied);

    function initialize(
        address hubV2, 
        string memory scopeSeed, 
        string memory uri_
    ) public initializer {
        __ERC1155_init(uri_);
        __EIP712_init("DataToken1155", "1");
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CURATOR_ROLE, msg.sender);
        // Wire Self
        __SelfVerificationRoot_init(hubV2, scopeSeed);
    }

    // Self → called after hub validates zk proof
    function customVerificationHook(
        ISelfVerificationRoot.GenericDiscloseOutputV2 memory output,
        bytes memory /*userData*/
    ) internal override {
        address user = output.wallet;
        zkPass[user] = ZkPass({
            validUntil: output.validUntil,
            issuedAt: output.issuedAt,
            version: 1
        });
        emit ZkPassIssued(user, output.validUntil);
    }

    // PermitForAll (operator approvals) – compatible with Lighthouse "Custom Contract" checks
    function permit(
        address owner, 
        address operator, 
        bool approved, 
        uint256 deadline,
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "DataToken1155: permit expired");

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            PERMIT_TYPEHASH, 
            owner, 
            operator, 
            approved, 
            nonces[owner]++, 
            deadline
        )));

        address recovered = digest.recover(v, r, s);
        require(recovered != address(0) && recovered == owner, "DataToken1155: invalid signature");

        _setApprovalForAll(owner, operator, approved);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }



    // Mint/transfer guards
    modifier requiresFreshSelf(address user) {
        ZkPass memory p = zkPass[user];
        require(!denylist[user], "DataToken1155: user denylisted");
        require(p.validUntil >= block.timestamp, "DataToken1155: zk pass expired");
        _;
    }

    function mint(
        bytes32 datasetId, 
        address to, 
        uint256 id, 
        uint256 amount, 
        bytes memory data
    ) external requiresFreshSelf(to) onlyRole(CURATOR_ROLE) {
        _mint(to, id, amount, data);
        datasetSubscriber[datasetId][to] = true;
        emit DatasetAccessGranted(datasetId, to);
    }

    function setDatasetAccess(
        bytes32 datasetId, 
        address user, 
        bool accessGranted
    ) external onlyRole(CURATOR_ROLE) {
        datasetSubscriber[datasetId][user] = accessGranted;
        if (accessGranted) {
            emit DatasetAccessGranted(datasetId, user);
        }
    }

    function _update(
    address from,
    address to,
    uint256[] memory ids,
    uint256[] memory values
) internal virtual override {
    // Enforce recipient gating on mints/transfers; skip burns (to == address(0))
    if (to != address(0)) {
        ZkPass memory p = zkPass[to];
        require(!denylist[to], "recipient denylisted");
        require(p.validUntil >= block.timestamp, "recipient zk pass expired");
    }

    // Delegate to OpenZeppelin ERC1155Upgradeable core
    super._update(from, to, ids, values);
}





    // Lighthouse will call this view in its Access Control Conditions (Custom Contract)
    function hasAccess(bytes32 datasetId, address user) external view returns (bool) {
        return datasetSubscriber[datasetId][user] && 
               !denylist[user] && 
               zkPass[user].validUntil >= block.timestamp;
    }

    // Admin functions
    function setDenylist(address user, bool denied) external onlyRole(DEFAULT_ADMIN_ROLE) {
        denylist[user] = denied;
        emit UserDenylisted(user, denied);
    }

    // UUPS
    function _authorizeUpgrade(address newImpl) internal override onlyRole(UPGRADER_ROLE) {}

    // The following functions are overrides required by Solidity
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}