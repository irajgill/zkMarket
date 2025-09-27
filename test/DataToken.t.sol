// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DataToken1155} from "../contracts/DataToken1155.sol";
import {MockSelfHub} from "../contracts/mocks/MockSelfHub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract DataTokenTest is Test {
    DataToken1155 public dataToken;
    DataToken1155 public dataTokenImpl;
    MockSelfHub public selfHub;

    address public owner = address(0x1);
    address public curator = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);

    bytes32 public constant DATASET_ID = keccak256("test-dataset");

    event ZkPassIssued(address indexed user, uint64 validUntil);
    event DatasetAccessGranted(bytes32 indexed datasetId, address indexed user);

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock Self hub
        selfHub = new MockSelfHub();

        // Deploy implementation
        dataTokenImpl = new DataToken1155();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            DataToken1155.initialize.selector,
            address(selfHub),
            "test-scope",
            "https://example.com/metadata/{id}"
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(dataTokenImpl), initData);
        dataToken = DataToken1155(address(proxy));

        // Grant curator role
        dataToken.grantRole(dataToken.CURATOR_ROLE(), curator);

        vm.stopPrank();
    }

    function test_Initialize() public {
        assertEq(dataToken.hasRole(dataToken.DEFAULT_ADMIN_ROLE(), owner), true);
        assertEq(dataToken.hasRole(dataToken.CURATOR_ROLE(), curator), true);
        assertEq(address(dataToken.selfHub()), address(selfHub));
    }

    function test_ZkVerification() public {
        vm.startPrank(user1);

        // Mock Self verification
        selfHub.setVerified(user1, true);

        // Verify user gets zk pass
        vm.expectEmit(true, false, false, true);
        emit ZkPassIssued(user1, uint64(block.timestamp + 30 days));

        bytes memory proof = abi.encode("mock_proof", block.timestamp);
        dataToken.verifySelfProof(proof, "");

        // Check zk pass was issued
        (uint64 validUntil, uint64 issuedAt, uint32 version) = dataToken.zkPass(user1);
        assertEq(validUntil, uint64(block.timestamp + 30 days));
        assertEq(issuedAt, uint64(block.timestamp));
        assertEq(version, 1);

        vm.stopPrank();
    }

    function test_MintWithValidZkPass() public {
        // Setup: Give user1 a valid zk pass
        vm.startPrank(user1);
        selfHub.setVerified(user1, true);
        bytes memory proof = abi.encode("mock_proof", block.timestamp);
        dataToken.verifySelfProof(proof, "");
        vm.stopPrank();

        // Mint token
        vm.startPrank(curator);

        vm.expectEmit(true, true, false, false);
        emit DatasetAccessGranted(DATASET_ID, user1);

        dataToken.mint(DATASET_ID, user1, 1, 1, "");

        // Check balance and access
        assertEq(dataToken.balanceOf(user1, 1), 1);
        assertEq(dataToken.hasAccess(DATASET_ID, user1), true);

        vm.stopPrank();
    }

    function test_MintFailsWithoutZkPass() public {
        vm.startPrank(curator);

        vm.expectRevert("DataToken1155: zk pass expired");
        dataToken.mint(DATASET_ID, user1, 1, 1, "");

        vm.stopPrank();
    }

    function test_MintFailsWithExpiredZkPass() public {
        // Setup: Give user1 a zk pass then make it expire
        vm.startPrank(user1);
        selfHub.setVerified(user1, true);
        bytes memory proof = abi.encode("mock_proof", block.timestamp);
        dataToken.verifySelfProof(proof, "");
        vm.stopPrank();

        // Fast forward time to expire the pass
        vm.warp(block.timestamp + 31 days);

        vm.startPrank(curator);
        vm.expectRevert("DataToken1155: zk pass expired");
        dataToken.mint(DATASET_ID, user1, 1, 1, "");
        vm.stopPrank();
    }

    function test_MintFailsWithDenylistedUser() public {
        // Setup: Give user1 a valid zk pass
        vm.startPrank(user1);
        selfHub.setVerified(user1, true);
        bytes memory proof = abi.encode("mock_proof", block.timestamp);
        dataToken.verifySelfProof(proof, "");
        vm.stopPrank();

        // Denylist user1
        vm.startPrank(owner);
        dataToken.setDenylist(user1, true);
        vm.stopPrank();

        // Attempt to mint
        vm.startPrank(curator);
        vm.expectRevert("DataToken1155: user denylisted");
        dataToken.mint(DATASET_ID, user1, 1, 1, "");
        vm.stopPrank();
    }

    function test_Permit() public {
        // Setup: Give user1 a valid zk pass and tokens
        vm.startPrank(user1);
        selfHub.setVerified(user1, true);
        bytes memory proof = abi.encode("mock_proof", block.timestamp);
        dataToken.verifySelfProof(proof, "");
        vm.stopPrank();

        vm.prank(curator);
        dataToken.mint(DATASET_ID, user1, 1, 1, "");

        // Create permit signature
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = dataToken.nonces(user1);

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            dataToken.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                dataToken.PERMIT_TYPEHASH(),
                user1,
                user2,
                true,
                nonce,
                deadline
            ))
        ));

        // Mock signature (in real test, use vm.sign)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(uint160(user1)), digest);

        // Execute permit
        dataToken.permit(user1, user2, true, deadline, v, r, s);

        // Check approval
        assertEq(dataToken.isApprovedForAll(user1, user2), true);
        assertEq(dataToken.nonces(user1), nonce + 1);
    }

    function test_TransferFailsToExpiredUser() public {
        // Setup: Give both users valid zk passes and user1 some tokens
        vm.startPrank(user1);
        selfHub.setVerified(user1, true);
        bytes memory proof1 = abi.encode("mock_proof1", block.timestamp);
        dataToken.verifySelfProof(proof1, "");
        vm.stopPrank();

        vm.startPrank(user2);
        selfHub.setVerified(user2, true);
        bytes memory proof2 = abi.encode("mock_proof2", block.timestamp);
        dataToken.verifySelfProof(proof2, "");
        vm.stopPrank();

        vm.prank(curator);
        dataToken.mint(DATASET_ID, user1, 1, 1, "");

        // Expire user2's zk pass
        vm.warp(block.timestamp + 31 days);

        // Attempt transfer
        vm.startPrank(user1);
        vm.expectRevert("DataToken1155: recipient zk pass expired");
        dataToken.safeTransferFrom(user1, user2, 1, 1, "");
        vm.stopPrank();
    }

    function test_HasAccessView() public {
        // Initially no access
        assertEq(dataToken.hasAccess(DATASET_ID, user1), false);

        // Setup: Give user1 a valid zk pass
        vm.startPrank(user1);
        selfHub.setVerified(user1, true);
        bytes memory proof = abi.encode("mock_proof", block.timestamp);
        dataToken.verifySelfProof(proof, "");
        vm.stopPrank();

        // Grant access manually (simulating subscription)
        vm.prank(curator);
        dataToken.setDatasetAccess(DATASET_ID, user1, true);

        // Should have access now
        assertEq(dataToken.hasAccess(DATASET_ID, user1), true);

        // Denylist user
        vm.prank(owner);
        dataToken.setDenylist(user1, true);

        // Should lose access
        assertEq(dataToken.hasAccess(DATASET_ID, user1), false);
    }

    function test_UpgradeAuthorization() public {
    address newImpl = address(new DataToken1155());

    // Only upgrader role can upgrade
    vm.startPrank(user1);
    vm.expectRevert(abi.encodeWithSelector(
        AccessControlUnauthorizedAccount.selector,
        user1,
        dataToken.UPGRADER_ROLE()
    ));
    dataToken.upgradeToAndCall(newImpl, "");
    vm.stopPrank();

    // Owner can upgrade (has upgrader role by default)
    vm.startPrank(owner);
    dataToken.upgradeToAndCall(newImpl, "");
    vm.stopPrank();
}

    

    function testFuzz_PermitWithRandomSignatures(
        uint256 privateKey,
        uint256 deadline,
        bool approved
    ) public {
        vm.assume(privateKey != 0 && privateKey < 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141);
        vm.assume(deadline > block.timestamp);

        address signer = vm.addr(privateKey);

        // Setup signer with valid zk pass
        vm.startPrank(signer);
        selfHub.setVerified(signer, true);
        bytes memory proof = abi.encode("mock_proof", block.timestamp, signer);
        dataToken.verifySelfProof(proof, "");
        vm.stopPrank();

        uint256 nonce = dataToken.nonces(signer);

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            dataToken.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                dataToken.PERMIT_TYPEHASH(),
                signer,
                user2,
                approved,
                nonce,
                deadline
            ))
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        dataToken.permit(signer, user2, approved, deadline, v, r, s);

        assertEq(dataToken.isApprovedForAll(signer, user2), approved);
        assertEq(dataToken.nonces(signer), nonce + 1);
    }
}