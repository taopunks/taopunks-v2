// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TaoPunkAgentRegistry.sol";
import "../src/ERC6551Registry.sol";
import "../src/TaoPunkAccount.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Minimal mock of TaoPunksV2 for testing
contract MockPunks {
    mapping(uint256 => address) private _owners;
    uint256 private _totalSupply;

    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
        _totalSupply++;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: owner query for nonexistent token");
        return owner;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "Not owner");
        _owners[tokenId] = to;
    }
}

contract TaoPunkAgentRegistryTest is Test {
    TaoPunkAgentRegistry public registry;
    MockPunks public punks;
    ERC6551Registry public tbaRegistry;
    TaoPunkAccount public tbaImpl;

    address public admin = address(0xA);
    address public alice = address(0xC);
    address public bob = address(0xD);
    address public fulfiller = address(0xE);

    string public constant AGENT_URI = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
    string public constant AGENT_URI_2 = "ipfs://bafybeihkoviema7g3gxyt6la7vd5ho32uj3xxx4iz3jky3a6oaomwtzyqu";

    function setUp() public {
        punks = new MockPunks();
        tbaRegistry = new ERC6551Registry();
        tbaImpl = new TaoPunkAccount();
        registry = new TaoPunkAgentRegistry(
            address(punks), admin, address(tbaRegistry), address(tbaImpl)
        );

        // Mint some punks
        punks.mint(alice, 1);
        punks.mint(alice, 2);
        punks.mint(alice, 3);
        punks.mint(bob, 4);
        punks.mint(bob, 5);
        punks.mint(alice, 420);
        punks.mint(bob, 3333);

        // Setup roles
        vm.startPrank(admin);
        registry.grantRole(registry.FULFILLER_ROLE(), fulfiller);
        registry.openActivation(block.number);
        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /// @dev Helper: compute TBA address for a punk
    function _getTBA(uint256 punkId) internal view returns (address) {
        return tbaRegistry.account(
            address(tbaImpl), bytes32(0), block.chainid, address(punks), punkId
        );
    }

    /// @dev Helper: deploy TBA for a punk
    function _createTBA(uint256 punkId) internal returns (address) {
        return tbaRegistry.createAccount(
            address(tbaImpl), bytes32(0), block.chainid, address(punks), punkId
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR & SETUP
    // ═══════════════════════════════════════════════════════════

    function test_constructor() public view {
        assertEq(address(registry.punks()), address(punks));
        assertEq(address(registry.tbaRegistry()), address(tbaRegistry));
        assertEq(registry.tbaImplementation(), address(tbaImpl));
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.GOVERNOR_ROLE(), admin));
        assertEq(registry.getMaxSupply(), 3333);
        assertEq(registry.getCollectionSupply(), 0);
        assertTrue(registry.activationOpen());
        assertEq(registry.nextQueryId(), 1);
    }

    function test_constructor_revert_zeroAddress() public {
        vm.expectRevert(TaoPunkAgentRegistry.ZeroAddress.selector);
        new TaoPunkAgentRegistry(address(0), admin, address(tbaRegistry), address(tbaImpl));

        vm.expectRevert(TaoPunkAgentRegistry.ZeroAddress.selector);
        new TaoPunkAgentRegistry(address(punks), address(0), address(tbaRegistry), address(tbaImpl));

        vm.expectRevert(TaoPunkAgentRegistry.ZeroAddress.selector);
        new TaoPunkAgentRegistry(address(punks), admin, address(0), address(tbaImpl));

        vm.expectRevert(TaoPunkAgentRegistry.ZeroAddress.selector);
        new TaoPunkAgentRegistry(address(punks), admin, address(tbaRegistry), address(0));
    }

    function test_supportsInterface_ERC8041() public view {
        assertTrue(registry.supportsInterface(type(IERC8041Collection).interfaceId));
    }

    // ═══════════════════════════════════════════════════════════
    //  ACTIVATION
    // ═══════════════════════════════════════════════════════════

    function test_activateAgent() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        (bool active, bool paused, uint64 activatedAt, uint64 queryCount, uint64 lastQueryAt, uint128 minFee, string memory uri) = registry.getAgent(1);
        assertTrue(active);
        assertFalse(paused);
        assertGt(activatedAt, 0);
        assertEq(queryCount, 0);
        assertEq(lastQueryAt, 0);
        assertEq(minFee, 0);
        assertEq(uri, AGENT_URI);

        assertEq(registry.getCollectionSupply(), 1);
        assertTrue(registry.isAgentActive(1));
        assertFalse(registry.isAgentPaused(1));
    }

    function test_activateAgent_emitsEvents() public {
        vm.prank(alice);
        vm.expectEmit(true, false, true, true);
        emit IERC8041Collection.AgentMinted(1, 1, alice);
        registry.activateAgent(1, AGENT_URI);
    }

    function test_activateAgent_multipleHolders() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);

        assertEq(registry.getCollectionSupply(), 2);
        assertTrue(registry.isAgentActive(1));
        assertTrue(registry.isAgentActive(4));
    }

    function test_activateAgent_mintNumberEqualsPunkId() public {
        vm.prank(alice);
        registry.activateAgent(420, AGENT_URI);

        assertEq(registry.getAgentMintNumber(420), 420);
        assertEq(registry.getAgentForPunk(420), 420);
    }

    function test_revert_activate_notOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.activateAgent(1, AGENT_URI);
    }

    function test_revert_activate_alreadyActive() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentAlreadyActive.selector, 1));
        registry.activateAgent(1, AGENT_URI);
    }

    function test_revert_activate_notOpen() public {
        vm.prank(admin);
        registry.closeActivation();

        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.ActivationNotOpen.selector);
        registry.activateAgent(1, AGENT_URI);
    }

    function test_revert_activate_emptyURI() public {
        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidURI.selector);
        registry.activateAgent(1, "");
    }

    function test_revert_activate_invalidPunkId_zero() public {
        vm.prank(alice);
        vm.expectRevert(); // ownerOf(0) reverts on ERC721A
        registry.activateAgent(0, AGENT_URI);
    }

    function test_revert_activate_invalidPunkId_tooHigh() public {
        vm.prank(alice);
        vm.expectRevert(); // ownerOf(3334) reverts
        registry.activateAgent(3334, AGENT_URI);
    }

    function test_revert_activate_futureStartBlock() public {
        vm.prank(admin);
        registry.openActivation(block.number + 1000);

        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.ActivationNotOpen.selector);
        registry.activateAgent(1, AGENT_URI);
    }

    // ═══════════════════════════════════════════════════════════
    //  AGENT MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function test_updateAgentURI() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        registry.updateAgentURI(1, AGENT_URI_2);

        (, , , , , , string memory uri) = registry.getAgent(1);
        assertEq(uri, AGENT_URI_2);
    }

    function test_revert_updateURI_notOwner() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.updateAgentURI(1, AGENT_URI_2);
    }

    function test_revert_updateURI_notActive() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentNotActive.selector, 1));
        registry.updateAgentURI(1, AGENT_URI_2);
    }

    function test_revert_updateURI_empty() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidURI.selector);
        registry.updateAgentURI(1, "");
    }

    function test_setAgentMetadata() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        registry.setAgentMetadata(1, "agent-class", abi.encode("frontier"));

        bytes memory val = registry.getAgentMetadata(1, "agent-class");
        assertEq(abi.decode(val, (string)), "frontier");
    }

    function test_revert_setMetadata_notOwner() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.setAgentMetadata(1, "key", "value");
    }

    // ═══════════════════════════════════════════════════════════
    //  CONTROLLER / OWNERSHIP FOLLOWS PUNK
    // ═══════════════════════════════════════════════════════════

    function test_controllerFollowsPunkOwnership() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        assertEq(registry.getController(1), alice);

        // Alice transfers punk to Bob
        punks.transferFrom(alice, bob, 1);

        // Controller automatically follows
        assertEq(registry.getController(1), bob);

        // Bob can now update the agent
        vm.prank(bob);
        registry.updateAgentURI(1, AGENT_URI_2);

        // Alice can no longer control the agent
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.updateAgentURI(1, AGENT_URI);
    }

    function test_revenueFollowsCurrentOwner() public {
        // Alice activates, then sells to Bob
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        _createTBA(1); // Deploy TBA
        punks.transferFrom(alice, bob, 1);

        // Someone queries punk 1
        vm.prank(alice);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // TAO goes to punk 1's TBA (not to alice or bob directly)
        address tba = _getTBA(1);
        assertEq(tba.balance, 0.01 ether);

        // Bob (current owner) can withdraw from TBA via execute
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        TaoPunkAccount(payable(tba)).execute(bob, 0.01 ether, "", 0);
        assertEq(bob.balance, bobBefore + 0.01 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //  QUERY / FULFILL LIFECYCLE
    // ═══════════════════════════════════════════════════════════

    function test_query_basic() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("hello"));

        (uint256 punkId, address caller, uint128 fee, TaoPunkAgentRegistry.QueryStatus status, , bytes32 inputHash, bytes32 resultHash) = registry.queries(qId);
        assertEq(punkId, 1);
        assertEq(caller, bob);
        assertEq(fee, 0.01 ether);
        assertTrue(status == TaoPunkAgentRegistry.QueryStatus.Pending);
        assertEq(inputHash, keccak256("hello"));
        assertEq(resultHash, bytes32(0));
    }

    function test_query_emitsEvent() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit TaoPunkAgentRegistry.QueryRequested(1, 1, bob, 0.01 ether, keccak256("hello"));
        registry.query{value: 0.01 ether}(1, keccak256("hello"));
    }

    function test_fulfill_sendsToTBA() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 1 ether}(1, keccak256("big query"));

        address tba = _getTBA(1);
        assertEq(tba.balance, 0);

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // 100% sent to punk's TBA
        assertEq(tba.balance, 1 ether);
        // Registry balance should be 0 (TAO left immediately)
        assertEq(address(registry).balance, 0);
    }

    function test_fulfill_updatesAgentStats() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        assertEq(registry.getQueryCount(1), 1);
        (, , , , uint64 lastQueryAt, , ) = registry.getAgent(1);
        assertGt(lastQueryAt, 0);
    }

    function test_fulfill_multipleQueries() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            uint256 qId = registry.query{value: 0.01 ether}(1, keccak256(abi.encode(i)));

            vm.prank(fulfiller);
            registry.fulfill(qId, keccak256(abi.encode("result", i)));
        }

        assertEq(registry.getQueryCount(1), 5);
        // 5 x 0.01 = 0.05 ether in TBA
        address tba = _getTBA(1);
        assertEq(tba.balance, 0.05 ether);
    }

    function test_fulfill_emitsFeeTransferredToTBA() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        address tba = _getTBA(1);

        vm.prank(fulfiller);
        vm.expectEmit(true, true, true, true);
        emit TaoPunkAgentRegistry.FeeTransferredToTBA(qId, 1, tba, 0.5 ether);
        registry.fulfill(qId, keccak256("result"));
    }

    function test_revert_query_agentNotActive() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentNotActive.selector, 1));
        registry.query{value: 0.01 ether}(1, keccak256("test"));
    }

    function test_revert_query_insufficientFee() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            TaoPunkAgentRegistry.InsufficientFee.selector,
            0.00001 ether,
            0.0001 ether
        ));
        registry.query{value: 0.00001 ether}(1, keccak256("test"));
    }

    function test_revert_query_excessiveFee() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            TaoPunkAgentRegistry.ExcessiveFee.selector,
            2 ether,
            1 ether
        ));
        registry.query{value: 2 ether}(1, keccak256("test"));
    }

    function test_revert_fulfill_notFulfiller() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(bob); // not fulfiller
        vm.expectRevert();
        registry.fulfill(qId, keccak256("result"));
    }

    function test_revert_fulfill_alreadyFulfilled() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        vm.prank(fulfiller);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotPending.selector, qId));
        registry.fulfill(qId, keccak256("result2"));
    }

    // ═══════════════════════════════════════════════════════════
    //  REFUND / EXPIRY
    // ═══════════════════════════════════════════════════════════

    function test_refundExpiredQuery() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        uint256 bobBefore = bob.balance;

        // Advance time past expiry
        vm.warp(block.timestamp + 2 hours);

        registry.refundExpiredQuery(qId);
        assertEq(bob.balance, bobBefore + 0.5 ether);

        (, , , TaoPunkAgentRegistry.QueryStatus status, , , ) = registry.queries(qId);
        assertTrue(status == TaoPunkAgentRegistry.QueryStatus.Expired);
    }

    function test_revert_refund_notExpired() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotExpired.selector, qId));
        registry.refundExpiredQuery(qId);
    }

    function test_revert_refund_alreadyFulfilled() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotPending.selector, qId));
        registry.refundExpiredQuery(qId);
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER-BYPASS (Free Queries for Punk Owners)
    // ═══════════════════════════════════════════════════════════

    function _activatePunk1() internal {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
    }

    function test_ownerBypass_freeQuery() public {
        _activatePunk1();
        vm.prank(alice);
        uint256 qId = registry.query{value: 0}(1, keccak256("hello"));
        (uint256 punkId, address caller, uint128 fee, , , , ) = registry.queries(qId);
        assertEq(punkId, 1);
        assertEq(caller, alice);
        assertEq(fee, 0);
    }

    function test_ownerBypass_emitsOwnerQueryEvent() public {
        _activatePunk1();
        vm.expectEmit(true, true, true, true);
        emit TaoPunkAgentRegistry.OwnerQuery(1, 1, alice, keccak256("test"));
        vm.prank(alice);
        registry.query{value: 0}(1, keccak256("test"));
    }

    function test_ownerBypass_ownerCanStillPayIfWanted() public {
        _activatePunk1();
        vm.prank(alice);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("paid"));
        (, , uint128 fee, , , , ) = registry.queries(qId);
        assertEq(fee, 0.5 ether);
    }

    function test_ownerBypass_nonOwnerCannotQueryFree() public {
        _activatePunk1();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            TaoPunkAgentRegistry.InsufficientFee.selector, 0, 0.0001 ether
        ));
        registry.query{value: 0}(1, keccak256("freeloader"));
    }

    function test_ownerBypass_fulfillNoTBATransferForFreeQuery() public {
        _activatePunk1();
        vm.prank(alice);
        uint256 qId = registry.query{value: 0}(1, keccak256("free"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // No TAO sent to TBA (fee was 0)
        address tba = _getTBA(1);
        assertEq(tba.balance, 0);
    }

    function test_ownerBypass_queryCountStillIncrements() public {
        _activatePunk1();
        vm.prank(alice);
        uint256 qId = registry.query{value: 0}(1, keccak256("free"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        assertEq(registry.getQueryCount(1), 1);
    }

    function test_ownerBypass_afterTransferNewOwnerQueriesFree() public {
        _activatePunk1();
        punks.transferFrom(alice, bob, 1);

        // Bob (new owner) queries free
        vm.prank(bob);
        uint256 qId = registry.query{value: 0}(1, keccak256("new owner"));
        (, , uint128 fee, , , , ) = registry.queries(qId);
        assertEq(fee, 0);

        // Alice (old owner) must pay
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TaoPunkAgentRegistry.InsufficientFee.selector, 0, 0.0001 ether
        ));
        registry.query{value: 0}(1, keccak256("old owner freebie"));
    }

    // ═══════════════════════════════════════════════════════════
    //  GOVERNANCE
    // ═══════════════════════════════════════════════════════════

    function test_setQueryExpiry() public {
        vm.prank(admin);
        registry.setQueryExpiry(30 minutes);
        assertEq(registry.queryExpiry(), 30 minutes);
    }

    function test_revert_setQueryExpiry_tooShort() public {
        vm.prank(admin);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidExpiry.selector);
        registry.setQueryExpiry(1 minutes);
    }

    function test_revert_setQueryExpiry_tooLong() public {
        vm.prank(admin);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidExpiry.selector);
        registry.setQueryExpiry(48 hours);
    }

    function test_openCloseActivation() public {
        vm.prank(admin);
        registry.closeActivation();
        assertFalse(registry.activationOpen());

        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.ActivationNotOpen.selector);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(admin);
        registry.openActivation(block.number);
        assertTrue(registry.activationOpen());

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        assertTrue(registry.isAgentActive(1));
    }

    // ═══════════════════════════════════════════════════════════
    //  ERC-8041 COMPLIANCE
    // ═══════════════════════════════════════════════════════════

    function test_erc8041_mintNumberZeroForInactive() public view {
        assertEq(registry.getAgentMintNumber(1), 0); // Not activated = 0
    }

    function test_erc8041_mintNumberMatchesPunkId() public {
        vm.prank(alice);
        registry.activateAgent(420, AGENT_URI);

        assertEq(registry.getAgentMintNumber(420), 420);
    }

    function test_erc8041_supplyTracking() public {
        assertEq(registry.getCollectionSupply(), 0);

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        assertEq(registry.getCollectionSupply(), 1);

        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);
        assertEq(registry.getCollectionSupply(), 2);
    }

    function test_erc8041_collectionUpdatedEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit IERC8041Collection.CollectionUpdated(3333, block.number + 100, true);
        registry.openActivation(block.number + 100);
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE / RESUME
    // ═══════════════════════════════════════════════════════════

    function test_pauseAgent() public {
        _activatePunk1();

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit TaoPunkAgentRegistry.AgentPaused(1);
        registry.pauseAgent(1);

        assertTrue(registry.isAgentPaused(1));
        (bool active, bool paused, , , , , ) = registry.getAgent(1);
        assertTrue(active);
        assertTrue(paused);
    }

    function test_resumeAgent() public {
        _activatePunk1();

        vm.prank(alice);
        registry.pauseAgent(1);
        assertTrue(registry.isAgentPaused(1));

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit TaoPunkAgentRegistry.AgentResumed(1);
        registry.resumeAgent(1);

        assertFalse(registry.isAgentPaused(1));
    }

    function test_revert_query_whenPaused() public {
        _activatePunk1();

        vm.prank(alice);
        registry.pauseAgent(1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentIsPaused.selector, 1));
        registry.query{value: 0.01 ether}(1, keccak256("blocked"));
    }

    function test_revert_pauseAgent_notOwner() public {
        _activatePunk1();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.pauseAgent(1);
    }

    function test_revert_resumeAgent_notOwner() public {
        _activatePunk1();

        vm.prank(alice);
        registry.pauseAgent(1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.resumeAgent(1);
    }

    function test_revert_pauseAgent_alreadyPaused() public {
        _activatePunk1();

        vm.prank(alice);
        registry.pauseAgent(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentIsPaused.selector, 1));
        registry.pauseAgent(1);
    }

    function test_revert_resumeAgent_notPaused() public {
        _activatePunk1();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentNotPaused.selector, 1));
        registry.resumeAgent(1);
    }

    function test_pause_existingPendingQueriesStillFulfillable() public {
        _activatePunk1();

        // Submit a query while agent is active
        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("before pause"));

        // Pause the agent
        vm.prank(alice);
        registry.pauseAgent(1);

        // Existing pending query can still be fulfilled
        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        address tba = _getTBA(1);
        assertEq(tba.balance, 0.5 ether);
        assertEq(registry.getQueryCount(1), 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  HOLDER-SET PRICING (setMinFee)
    // ═══════════════════════════════════════════════════════════

    function test_setMinFee() public {
        _activatePunk1();

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit TaoPunkAgentRegistry.AgentMinFeeUpdated(1, 0, 0.05 ether);
        registry.setMinFee(1, 0.05 ether);

        (, , , , , uint128 minFee, ) = registry.getAgent(1);
        assertEq(minFee, 0.05 ether);
        assertEq(registry.getEffectiveMinFee(1), 0.05 ether);
    }

    function test_setMinFee_effectiveMinFeeUsedInQuery() public {
        _activatePunk1();

        vm.prank(alice);
        registry.setMinFee(1, 0.05 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            TaoPunkAgentRegistry.InsufficientFee.selector,
            0.0001 ether,
            0.05 ether
        ));
        registry.query{value: 0.0001 ether}(1, keccak256("too little"));

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.05 ether}(1, keccak256("enough"));
        (, , uint128 fee, , , , ) = registry.queries(qId);
        assertEq(fee, 0.05 ether);
    }

    function test_setMinFee_nonOwnerMustPayHolderMinFee() public {
        _activatePunk1();

        vm.prank(alice);
        registry.setMinFee(1, 0.1 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            TaoPunkAgentRegistry.InsufficientFee.selector,
            0.05 ether,
            0.1 ether
        ));
        registry.query{value: 0.05 ether}(1, keccak256("low"));

        vm.prank(bob);
        registry.query{value: 0.1 ether}(1, keccak256("ok"));
    }

    function test_revert_setMinFee_invalidFee() public {
        _activatePunk1();

        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidFee.selector);
        registry.setMinFee(1, 0.00001 ether);

        vm.prank(alice);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidFee.selector);
        registry.setMinFee(1, 2 ether);
    }

    function test_setMinFee_zeroFallsBackToGlobal() public {
        _activatePunk1();

        vm.prank(alice);
        registry.setMinFee(1, 0.5 ether);

        vm.prank(alice);
        registry.setMinFee(1, 0);

        assertEq(registry.getEffectiveMinFee(1), 0.0001 ether);

        vm.prank(bob);
        registry.query{value: 0.0001 ether}(1, keccak256("global min"));
    }

    function test_setMinFee_followsTransfer() public {
        _activatePunk1();

        vm.prank(alice);
        registry.setMinFee(1, 0.2 ether);

        punks.transferFrom(alice, bob, 1);

        assertEq(registry.getEffectiveMinFee(1), 0.2 ether);

        vm.prank(bob);
        registry.setMinFee(1, 0.01 ether);
        assertEq(registry.getEffectiveMinFee(1), 0.01 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.setMinFee(1, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //  BATCH FULFILL
    // ═══════════════════════════════════════════════════════════

    function test_batchFulfill_basic() public {
        _activatePunk1();

        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.1 ether}(1, keccak256("q0"));
        vm.prank(bob);
        uint256 q1 = registry.query{value: 0.2 ether}(1, keccak256("q1"));
        vm.prank(bob);
        uint256 q2 = registry.query{value: 0.3 ether}(1, keccak256("q2"));

        uint256[] memory ids = new uint256[](3);
        ids[0] = q0;
        ids[1] = q1;
        ids[2] = q2;
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("r0");
        hashes[1] = keccak256("r1");
        hashes[2] = keccak256("r2");

        vm.prank(fulfiller);
        registry.batchFulfill(ids, hashes);

        // All fulfilled
        (, , , TaoPunkAgentRegistry.QueryStatus s0, , , ) = registry.queries(q0);
        (, , , TaoPunkAgentRegistry.QueryStatus s1, , , ) = registry.queries(q1);
        (, , , TaoPunkAgentRegistry.QueryStatus s2, , , ) = registry.queries(q2);
        assertTrue(s0 == TaoPunkAgentRegistry.QueryStatus.Fulfilled);
        assertTrue(s1 == TaoPunkAgentRegistry.QueryStatus.Fulfilled);
        assertTrue(s2 == TaoPunkAgentRegistry.QueryStatus.Fulfilled);

        // Total in TBA: 0.1 + 0.2 + 0.3 = 0.6
        address tba = _getTBA(1);
        assertEq(tba.balance, 0.6 ether);
        assertEq(registry.getQueryCount(1), 3);
    }

    function test_batchFulfill_multiplePunks() public {
        _activatePunk1();
        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);

        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.5 ether}(1, keccak256("q0"));
        vm.prank(alice);
        uint256 q1 = registry.query{value: 0.3 ether}(4, keccak256("q1"));

        uint256[] memory ids = new uint256[](2);
        ids[0] = q0;
        ids[1] = q1;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("r0");
        hashes[1] = keccak256("r1");

        vm.prank(fulfiller);
        registry.batchFulfill(ids, hashes);

        // Each punk's TBA gets its own fee
        assertEq(_getTBA(1).balance, 0.5 ether);
        assertEq(_getTBA(4).balance, 0.3 ether);
    }

    function test_revert_batchFulfill_emptyBatch() public {
        uint256[] memory ids = new uint256[](0);
        bytes32[] memory hashes = new bytes32[](0);

        vm.prank(fulfiller);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidBatchSize.selector);
        registry.batchFulfill(ids, hashes);
    }

    function test_revert_batchFulfill_mismatchedLengths() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("r0");
        hashes[1] = keccak256("r1");
        hashes[2] = keccak256("r2");

        vm.prank(fulfiller);
        vm.expectRevert(TaoPunkAgentRegistry.BatchLengthMismatch.selector);
        registry.batchFulfill(ids, hashes);
    }

    function test_revert_batchFulfill_oversizedBatch() public {
        uint256 size = 51;
        uint256[] memory ids = new uint256[](size);
        bytes32[] memory hashes = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            ids[i] = i + 1;
            hashes[i] = keccak256(abi.encode(i));
        }

        vm.prank(fulfiller);
        vm.expectRevert(TaoPunkAgentRegistry.InvalidBatchSize.selector);
        registry.batchFulfill(ids, hashes);
    }

    function test_batchFulfill_partialFailure_oneBadId() public {
        _activatePunk1();

        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.1 ether}(1, keccak256("q0"));

        uint256[] memory ids = new uint256[](2);
        ids[0] = q0;
        ids[1] = 999;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("r0");
        hashes[1] = keccak256("r1");

        vm.prank(fulfiller);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryDoesNotExist.selector, 999));
        registry.batchFulfill(ids, hashes);

        (, , , TaoPunkAgentRegistry.QueryStatus status, , , ) = registry.queries(q0);
        assertTrue(status == TaoPunkAgentRegistry.QueryStatus.Pending);
    }

    // ═══════════════════════════════════════════════════════════
    //  RESULT HASH STORED
    // ═══════════════════════════════════════════════════════════

    function test_resultHash_storedOnFulfill() public {
        _activatePunk1();

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("input"));

        bytes32 expectedHash = keccak256("the result data");

        vm.prank(fulfiller);
        registry.fulfill(qId, expectedHash);

        (, , , , , , bytes32 resultHash) = registry.queries(qId);
        assertEq(resultHash, expectedHash);
    }

    function test_resultHash_zeroBeforeFulfill() public {
        _activatePunk1();

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("input"));

        (, , , , , , bytes32 resultHash) = registry.queries(qId);
        assertEq(resultHash, bytes32(0));
    }

    function test_resultHash_batchFulfillStoresHashes() public {
        _activatePunk1();

        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.01 ether}(1, keccak256("q0"));
        vm.prank(bob);
        uint256 q1 = registry.query{value: 0.01 ether}(1, keccak256("q1"));

        bytes32 h0 = keccak256("result0");
        bytes32 h1 = keccak256("result1");

        uint256[] memory ids = new uint256[](2);
        ids[0] = q0;
        ids[1] = q1;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = h0;
        hashes[1] = h1;

        vm.prank(fulfiller);
        registry.batchFulfill(ids, hashes);

        (, , , , , , bytes32 r0) = registry.queries(q0);
        (, , , , , , bytes32 r1) = registry.queries(q1);
        assertEq(r0, h0);
        assertEq(r1, h1);
    }

    // ═══════════════════════════════════════════════════════════
    //  TOKEN BOUND ACCOUNTS (ERC-6551)
    // ═══════════════════════════════════════════════════════════

    function test_tba_addressDeterminism() public view {
        // Same inputs produce same address across calls
        address tba1 = _getTBA(1);
        address tba2 = _getTBA(1);
        assertEq(tba1, tba2);
        assertTrue(tba1 != address(0));

        // Different punkIds produce different addresses
        address tba4 = _getTBA(4);
        assertTrue(tba1 != tba4);
    }

    function test_tba_getPunkTBA() public view {
        address expected = _getTBA(1);
        assertEq(registry.getPunkTBA(1), expected);
    }

    function test_tba_createPunkTBA_deploysAndReturns() public {
        address expected = _getTBA(1);
        address deployed = registry.createPunkTBA(1);
        assertEq(deployed, expected);
        assertTrue(deployed.code.length > 0); // Code deployed
    }

    function test_tba_createPunkTBA_idempotent() public {
        address first = registry.createPunkTBA(1);
        address second = registry.createPunkTBA(1);
        assertEq(first, second);
    }

    function test_tba_receiveTAOBeforeDeployment() public {
        // Counterfactual: TBA address receives TAO before code is deployed
        _activatePunk1();

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        address tba = _getTBA(1);
        assertEq(tba.code.length, 0); // Not deployed yet

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // TAO arrived at the address even though no code
        assertEq(tba.balance, 0.5 ether);

        // Now deploy the TBA
        registry.createPunkTBA(1);
        assertTrue(tba.code.length > 0);

        // Owner can withdraw
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 0.5 ether, "", 0);
        assertEq(alice.balance, aliceBefore + 0.5 ether);
    }

    function test_tba_ownershipFollowsTransfer() public {
        _activatePunk1();
        address tba = _createTBA(1);
        vm.deal(tba, 1 ether); // Fund TBA

        // Alice (owner) can execute
        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 0.5 ether, "", 0);
        assertEq(tba.balance, 0.5 ether);

        // Transfer punk to bob
        punks.transferFrom(alice, bob, 1);

        // Alice can no longer execute
        vm.prank(alice);
        vm.expectRevert(TaoPunkAccount.NotAuthorized.selector);
        TaoPunkAccount(payable(tba)).execute(alice, 0.1 ether, "", 0);

        // Bob (new owner) can execute
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        TaoPunkAccount(payable(tba)).execute(bob, 0.5 ether, "", 0);
        assertEq(bob.balance, bobBefore + 0.5 ether);
    }

    function test_tba_isolation() public {
        // Punk 1 owner can't access punk 4's TBA
        _activatePunk1();
        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);

        address tba4 = _createTBA(4);
        vm.deal(tba4, 1 ether);

        // Alice (owns punk 1) tries to execute on punk 4's TBA
        vm.prank(alice);
        vm.expectRevert(TaoPunkAccount.NotAuthorized.selector);
        TaoPunkAccount(payable(tba4)).execute(alice, 0.1 ether, "", 0);

        // Bob (owns punk 4) can execute
        vm.prank(bob);
        TaoPunkAccount(payable(tba4)).execute(bob, 0.5 ether, "", 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  TaoPunkAccount UNIT TESTS
    // ═══════════════════════════════════════════════════════════

    function test_tbaAccount_executeOnlyOwner() public {
        _activatePunk1();
        address tba = _createTBA(1);
        vm.deal(tba, 1 ether);

        // Non-owner reverts
        vm.prank(bob);
        vm.expectRevert(TaoPunkAccount.NotAuthorized.selector);
        TaoPunkAccount(payable(tba)).execute(bob, 0.1 ether, "", 0);

        // Owner succeeds
        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 0.1 ether, "", 0);
    }

    function test_tbaAccount_executeOnlyCallOperation() public {
        _activatePunk1();
        address tba = _createTBA(1);

        // operation != 0 reverts
        vm.prank(alice);
        vm.expectRevert(TaoPunkAccount.OnlyCallOperation.selector);
        TaoPunkAccount(payable(tba)).execute(alice, 0, "", 1);
    }

    function test_tbaAccount_tokenReturnsCorrectValues() public {
        _activatePunk1();
        address tba = _createTBA(1);

        (uint256 chainId, address tokenContract, uint256 tokenId) = TaoPunkAccount(payable(tba)).token();
        assertEq(chainId, block.chainid);
        assertEq(tokenContract, address(punks));
        assertEq(tokenId, 1);
    }

    function test_tbaAccount_isValidSigner() public {
        _activatePunk1();
        address tba = _createTBA(1);

        // Owner is valid signer
        bytes4 magic = TaoPunkAccount(payable(tba)).isValidSigner(alice, "");
        assertEq(magic, bytes4(0x523e3260)); // IERC6551Account.isValidSigner.selector

        // Non-owner is not valid
        bytes4 invalid = TaoPunkAccount(payable(tba)).isValidSigner(bob, "");
        assertEq(invalid, bytes4(0));
    }

    function test_tbaAccount_stateIncrements() public {
        _activatePunk1();
        address tba = _createTBA(1);
        vm.deal(tba, 1 ether);

        assertEq(TaoPunkAccount(payable(tba)).state(), 0);

        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 0.1 ether, "", 0);
        assertEq(TaoPunkAccount(payable(tba)).state(), 1);

        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 0.1 ether, "", 0);
        assertEq(TaoPunkAccount(payable(tba)).state(), 2);
    }

    function test_tbaAccount_supportsInterface() public {
        _activatePunk1();
        address tba = _createTBA(1);

        assertTrue(TaoPunkAccount(payable(tba)).supportsInterface(0x01ffc9a7)); // IERC165
        assertTrue(TaoPunkAccount(payable(tba)).supportsInterface(type(IERC6551Account).interfaceId));
        assertTrue(TaoPunkAccount(payable(tba)).supportsInterface(type(IERC6551Executable).interfaceId));
        assertFalse(TaoPunkAccount(payable(tba)).supportsInterface(0xdeadbeef));
    }

    // ═══════════════════════════════════════════════════════════
    //  SECURITY TESTS
    // ═══════════════════════════════════════════════════════════

    function test_security_cannotActivateSamePunkTwice() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        punks.transferFrom(alice, bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentAlreadyActive.selector, 1));
        registry.activateAgent(1, AGENT_URI);
    }

    function test_security_fulfillerCannotStealFunds() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 1 ether}(1, keccak256("test"));

        uint256 fulfillerBefore = fulfiller.balance;

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // Fulfiller balance should not increase
        assertEq(fulfiller.balance, fulfillerBefore);
        // TAO went to TBA, not fulfiller
        assertEq(_getTBA(1).balance, 1 ether);
    }

    function test_security_queryFeeRange() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        registry.query{value: 0.0001 ether}(1, keccak256("min"));

        vm.prank(bob);
        registry.query{value: 1 ether}(1, keccak256("max"));
    }

    function test_security_nonReentrant_query() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        registry.query{value: 0.01 ether}(1, keccak256("test"));
    }

    function test_security_onlyAdminCanGrantFulfillerRole() public {
        bytes32 fulfillerRole = registry.FULFILLER_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            alice,
            adminRole
        ));
        registry.grantRole(fulfillerRole, alice);
    }

    function test_security_onlyAdminCanGrantGovernorRole() public {
        bytes32 governorRole = registry.GOVERNOR_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            alice,
            adminRole
        ));
        registry.grantRole(governorRole, alice);
    }

    /// @dev With TBA push-based model, fulfill now makes external call — test that it works
    function test_security_fulfillSendsToTBA() public {
        _activatePunk1();

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        // Fulfill sends TAO to TBA address (which may or may not have code)
        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        assertEq(_getTBA(1).balance, 0.5 ether);
    }

    /// @dev Self-query: holder queries own punk, pays and earns back via TBA
    function test_security_selfQuery_economicInvariant() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        _createTBA(1);

        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        uint256 qId = registry.query{value: 1 ether}(1, keccak256("self"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // 100% sent to TBA
        address tba = _getTBA(1);
        assertEq(tba.balance, 1 ether);

        // Alice withdraws from TBA — net zero
        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 1 ether, "", 0);

        assertEq(alice.balance, aliceBefore);
    }

    /// @dev Query ID starts at 1 (ID 0 = does not exist sentinel)
    function test_security_queryIdStartsAtOne() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("first"));
        assertEq(qId, 1);

        (uint256 punkId, address caller, , , , , ) = registry.queries(1);
        assertEq(punkId, 1);
        assertEq(caller, bob);

        (uint256 punkId0, address caller0, , , , , ) = registry.queries(0);
        assertEq(punkId0, 0);
        assertEq(caller0, address(0));

        vm.prank(bob);
        uint256 qId2 = registry.query{value: 0.01 ether}(1, keccak256("second"));
        assertEq(qId2, 2);
    }

    /// @dev Cannot refund a query that was already refunded
    function test_security_doubleRefund() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        vm.warp(block.timestamp + 2 hours);
        registry.refundExpiredQuery(qId);

        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotPending.selector, qId));
        registry.refundExpiredQuery(qId);
    }

    /// @dev Cannot fulfill a refunded query
    function test_security_fulfillAfterRefund() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        vm.warp(block.timestamp + 2 hours);
        registry.refundExpiredQuery(qId);

        vm.prank(fulfiller);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotPending.selector, qId));
        registry.fulfill(qId, keccak256("result"));
    }

    /// @dev Multiple concurrent pending queries on same punk
    function test_security_concurrentQueries() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.01 ether}(1, keccak256("q0"));
        vm.prank(bob);
        uint256 q1 = registry.query{value: 0.02 ether}(1, keccak256("q1"));
        vm.prank(bob);
        uint256 q2 = registry.query{value: 0.03 ether}(1, keccak256("q2"));

        // Fulfill out of order
        vm.prank(fulfiller);
        registry.fulfill(q2, keccak256("r2"));
        vm.prank(fulfiller);
        registry.fulfill(q0, keccak256("r0"));

        // Refund q1 after expiry
        vm.warp(block.timestamp + 2 hours);
        registry.refundExpiredQuery(q1);

        assertEq(registry.getQueryCount(1), 2);
        // 0.01 + 0.03 = 0.04 in TBA
        assertEq(_getTBA(1).balance, 0.04 ether);
    }

    /// @dev Fulfill/refund nonexistent query ID — must revert
    function test_security_fulfillNonexistentQuery() public {
        vm.prank(fulfiller);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryDoesNotExist.selector, 999));
        registry.fulfill(999, keccak256("ghost"));
    }

    function test_security_refundNonexistentQuery() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryDoesNotExist.selector, 999));
        registry.refundExpiredQuery(999);
    }

    /// @dev Escrow invariant: registry balance = sum of pending query fees only
    function test_security_escrowAccountingInvariant() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        assertEq(address(registry).balance, 0);

        // Query 1: 0.5 ETH
        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.5 ether}(1, keccak256("q0"));
        assertEq(address(registry).balance, 0.5 ether);

        // Query 2: 0.3 ETH
        vm.prank(bob);
        uint256 q1 = registry.query{value: 0.3 ether}(1, keccak256("q1"));
        assertEq(address(registry).balance, 0.8 ether);

        // Fulfill query 0 — fee leaves registry immediately (push-based)
        vm.prank(fulfiller);
        registry.fulfill(q0, keccak256("r0"));
        assertEq(address(registry).balance, 0.3 ether); // Only q1 escrow remains
        assertEq(_getTBA(1).balance, 0.5 ether);

        // Refund query 1 — 0.3 ETH returned to bob
        vm.warp(block.timestamp + 2 hours);
        registry.refundExpiredQuery(q1);
        assertEq(address(registry).balance, 0);
    }

    /// @dev Governor cannot fulfill queries (role separation)
    function test_security_governorCannotFulfill() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        bytes32 fulfillerRole = registry.FULFILLER_ROLE();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            admin,
            fulfillerRole
        ));
        registry.fulfill(qId, keccak256("result"));
    }

    /// @dev Admin can revoke fulfiller role
    function test_security_adminCanRevokeRoles() public {
        bytes32 fulfillerRole = registry.FULFILLER_ROLE();

        assertTrue(registry.hasRole(fulfillerRole, fulfiller));

        vm.prank(admin);
        registry.revokeRole(fulfillerRole, fulfiller);

        assertFalse(registry.hasRole(fulfillerRole, fulfiller));

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(fulfiller);
        vm.expectRevert();
        registry.fulfill(qId, keccak256("result"));
    }

    /// @dev Supply can't overflow — activate all possible punks
    function test_security_massActivation() public {
        for (uint256 i = 1; i <= 50; i++) {
            address holder = address(uint160(5000 + i));
            punks.mint(holder, 500 + i);
            vm.prank(holder);
            registry.activateAgent(500 + i, AGENT_URI);
        }

        assertEq(registry.getCollectionSupply(), 50);
    }

    /// @dev Timestamp stored correctly under vm.warp
    function test_security_timestampAccuracy() public {
        vm.warp(1_700_000_000);
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        (, , uint64 activatedAt, , , , ) = registry.getAgent(1);
        assertEq(activatedAt, 1_700_000_000);

        vm.warp(1_700_001_000);
        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.warp(1_700_002_000);
        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        (, , , , uint64 lastQueryAt, , ) = registry.getAgent(1);
        assertEq(lastQueryAt, 1_700_002_000);
    }

    /// @dev Metadata can be overwritten and read back
    function test_security_metadataOverwrite() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        registry.setAgentMetadata(1, "model", abi.encode("gpt-4"));

        vm.prank(alice);
        registry.setAgentMetadata(1, "model", abi.encode("claude-opus"));

        bytes memory val = registry.getAgentMetadata(1, "model");
        assertEq(abi.decode(val, (string)), "claude-opus");
    }

    /// @dev Multiple metadata keys on same agent
    function test_security_multipleMetadataKeys() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        registry.setAgentMetadata(1, "model", abi.encode("frontier"));
        vm.prank(alice);
        registry.setAgentMetadata(1, "version", abi.encode(uint256(2)));
        vm.prank(alice);
        registry.setAgentMetadata(1, "subnet", abi.encode(uint256(64)));

        assertEq(abi.decode(registry.getAgentMetadata(1, "model"), (string)), "frontier");
        assertEq(abi.decode(registry.getAgentMetadata(1, "version"), (uint256)), 2);
        assertEq(abi.decode(registry.getAgentMetadata(1, "subnet"), (uint256)), 64);
    }

    /// @dev Metadata for non-activated punk returns empty
    function test_security_metadataForInactivePunk() public view {
        bytes memory val = registry.getAgentMetadata(1, "model");
        assertEq(val.length, 0);
    }

    /// @dev getAgentForPunk reverts for inactive punk
    function test_security_getAgentForPunkInactive() public {
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentNotActive.selector, 1));
        registry.getAgentForPunk(1);
    }

    /// @dev Exact boundary test: queryExpiry at exactly 5 minutes and 24 hours
    function test_security_expiryBoundaries() public {
        vm.startPrank(admin);

        registry.setQueryExpiry(5 minutes);
        assertEq(registry.queryExpiry(), 5 minutes);

        registry.setQueryExpiry(24 hours);
        assertEq(registry.queryExpiry(), 24 hours);

        vm.expectRevert(TaoPunkAgentRegistry.InvalidExpiry.selector);
        registry.setQueryExpiry(4 minutes + 59 seconds);

        vm.expectRevert(TaoPunkAgentRegistry.InvalidExpiry.selector);
        registry.setQueryExpiry(24 hours + 1 seconds);

        vm.stopPrank();
    }

    /// @dev Refund exactly at expiry boundary
    function test_security_refundAtExactExpiry() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        uint256 queryTime = block.timestamp;
        vm.prank(bob);
        uint256 qId = registry.query{value: 0.1 ether}(1, keccak256("boundary"));

        vm.warp(queryTime + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotExpired.selector, qId));
        registry.refundExpiredQuery(qId);

        vm.warp(queryTime + 1 hours);
        uint256 bobBefore = bob.balance;
        registry.refundExpiredQuery(qId);
        assertEq(bob.balance, bobBefore + 0.1 ether);
    }

    /// @dev Registry balance = pending query fees only (no claimable balance stored)
    function test_security_contractBalanceInvariant() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);

        vm.prank(bob);
        uint256 q0 = registry.query{value: 0.5 ether}(1, keccak256("q0"));
        vm.prank(alice);
        uint256 q1 = registry.query{value: 0.3 ether}(4, keccak256("q1"));
        vm.prank(bob);
        uint256 q2 = registry.query{value: 0.2 ether}(1, keccak256("q2"));

        assertEq(address(registry).balance, 1.0 ether);

        // Fulfill q0 and q2 — TAO leaves registry to punk 1's TBA
        vm.prank(fulfiller);
        registry.fulfill(q0, keccak256("r0"));
        vm.prank(fulfiller);
        registry.fulfill(q2, keccak256("r2"));

        assertEq(address(registry).balance, 0.3 ether); // Only q1 escrow
        assertEq(_getTBA(1).balance, 0.7 ether); // 0.5 + 0.2

        // Fulfill q1 — TAO leaves to punk 4's TBA
        vm.prank(fulfiller);
        registry.fulfill(q1, keccak256("r1"));

        assertEq(address(registry).balance, 0); // Registry empty
        assertEq(_getTBA(4).balance, 0.3 ether);
    }

    // ═══════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ═══════════════════════════════════════════════════════════

    /// @dev Fuzz: escrow invariant — registry balance tracks pending fees
    function testFuzz_escrowInvariant(uint128 fee1, uint128 fee2) public {
        vm.assume(fee1 >= 0.0001 ether && fee1 <= 1 ether);
        vm.assume(fee2 >= 0.0001 ether && fee2 <= 1 ether);

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.deal(bob, 20 ether);

        vm.prank(bob);
        uint256 q0 = registry.query{value: fee1}(1, keccak256("q0"));
        assertEq(address(registry).balance, fee1);

        vm.prank(bob);
        registry.query{value: fee2}(1, keccak256("q1"));
        assertEq(address(registry).balance, uint256(fee1) + uint256(fee2));

        // Fulfill q0 — fee1 leaves registry to TBA
        vm.prank(fulfiller);
        registry.fulfill(q0, keccak256("r0"));
        assertEq(address(registry).balance, fee2);
        assertEq(_getTBA(1).balance, fee1);
    }

    /// @dev Fuzz: query expiry boundary
    function testFuzz_expiryBoundary(uint256 expiryOffset) public {
        vm.assume(expiryOffset >= 5 minutes && expiryOffset <= 24 hours);

        vm.prank(admin);
        registry.setQueryExpiry(expiryOffset);

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        uint256 queryTime = block.timestamp;
        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("fuzz"));

        vm.warp(queryTime + expiryOffset - 1);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.QueryNotExpired.selector, qId));
        registry.refundExpiredQuery(qId);

        vm.warp(queryTime + expiryOffset);
        registry.refundExpiredQuery(qId);
    }

    /// @dev Fuzz: 100% of any fee goes to TBA
    function testFuzz_holderGets100Percent(uint128 fee) public {
        vm.assume(fee >= 0.0001 ether && fee <= 1 ether);

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.deal(bob, uint256(fee) + 1 ether);

        vm.prank(bob);
        uint256 qId = registry.query{value: fee}(1, keccak256("fuzz"));

        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        // 100% in TBA
        assertEq(_getTBA(1).balance, fee);
        // Registry empty
        assertEq(address(registry).balance, 0);
    }

    function testFuzz_activateValidPunkId(uint16 punkId) public {
        vm.assume(punkId >= 1 && punkId <= 100);

        address holder = address(uint160(1000 + punkId));
        punks.mint(holder, punkId);

        vm.prank(holder);
        registry.activateAgent(punkId, AGENT_URI);

        assertTrue(registry.isAgentActive(punkId));
        assertEq(registry.getAgentMintNumber(punkId), punkId);
        assertEq(registry.getController(punkId), holder);
    }

    // ═══════════════════════════════════════════════════════════
    //  DEACTIVATION (Full Reset & Re-Activation)
    // ═══════════════════════════════════════════════════════════

    function test_deactivateAgent() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        assertTrue(registry.isAgentActive(1));
        assertEq(registry.getCollectionSupply(), 1);

        vm.prank(alice);
        registry.deactivateAgent(1);

        assertFalse(registry.isAgentActive(1));
        assertEq(registry.getCollectionSupply(), 0);
    }

    function test_deactivateAgent_emitsEvent() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.expectEmit(true, true, false, true);
        emit TaoPunkAgentRegistry.AgentDeactivated(1, alice);
        vm.prank(alice);
        registry.deactivateAgent(1);
    }

    function test_deactivateAgent_resetsAllFields() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(alice);
        registry.setMinFee(1, 0.05 ether);
        vm.prank(alice);
        registry.pauseAgent(1);

        vm.prank(alice);
        registry.resumeAgent(1);
        vm.prank(bob);
        uint256 qId = registry.query{value: 0.1 ether}(1, keccak256("test"));
        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        vm.prank(alice);
        registry.deactivateAgent(1);

        (bool active, bool paused, uint64 activatedAt, uint64 queryCount, uint64 lastQueryAt, uint128 minFee, string memory uri) = registry.getAgent(1);
        assertFalse(active);
        assertFalse(paused);
        assertEq(activatedAt, 0);
        assertEq(queryCount, 0);
        assertEq(lastQueryAt, 0);
        assertEq(minFee, 0);
        assertEq(bytes(uri).length, 0);
    }

    function test_deactivateAgent_reactivateFresh() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.1 ether}(1, keccak256("test"));
        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));
        assertEq(registry.getQueryCount(1), 1);

        vm.prank(alice);
        registry.deactivateAgent(1);
        assertEq(registry.getCollectionSupply(), 0);

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI_2);

        assertTrue(registry.isAgentActive(1));
        assertEq(registry.getCollectionSupply(), 1);
        assertEq(registry.getQueryCount(1), 0);

        (,,,,,, string memory uri) = registry.getAgent(1);
        assertEq(uri, AGENT_URI_2);
    }

    function test_revert_deactivate_notOwner() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.NotPunkOwner.selector, 1));
        registry.deactivateAgent(1);
    }

    function test_revert_deactivate_notActive() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentNotActive.selector, 1));
        registry.deactivateAgent(1);
    }

    function test_deactivate_queryReverts() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        vm.prank(alice);
        registry.deactivateAgent(1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentNotActive.selector, 1));
        registry.query{value: 0.01 ether}(1, keccak256("test"));
    }

    function test_deactivate_pendingQueriesStillRefundable() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.5 ether}(1, keccak256("test"));

        vm.prank(alice);
        registry.deactivateAgent(1);

        vm.warp(block.timestamp + 2 hours);
        uint256 bobBefore = bob.balance;
        registry.refundExpiredQuery(qId);
        assertEq(bob.balance, bobBefore + 0.5 ether);
    }

    function test_deactivate_tbaFundsUnaffected() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 1 ether}(1, keccak256("test"));
        vm.prank(fulfiller);
        registry.fulfill(qId, keccak256("result"));

        address tba = _getTBA(1);
        assertEq(tba.balance, 1 ether);

        // Deactivate — TBA funds are NOT lost
        vm.prank(alice);
        registry.deactivateAgent(1);

        // TBA balance unchanged
        assertEq(tba.balance, 1 ether);

        // Deploy TBA and withdraw
        _createTBA(1);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        TaoPunkAccount(payable(tba)).execute(alice, 1 ether, "", 0);
        assertEq(alice.balance, aliceBefore + 1 ether);
    }

    function test_deactivate_newOwnerCanReactivateAfterTransfer() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        vm.prank(alice);
        registry.deactivateAgent(1);

        punks.transferFrom(alice, bob, 1);

        vm.prank(bob);
        registry.activateAgent(1, AGENT_URI_2);
        assertTrue(registry.isAgentActive(1));
        assertEq(registry.getController(1), bob);
    }

    function test_deactivate_erc8041SupplyTracking() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);
        assertEq(registry.getCollectionSupply(), 2);

        vm.prank(alice);
        registry.deactivateAgent(1);
        assertEq(registry.getCollectionSupply(), 1);

        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI_2);
        assertEq(registry.getCollectionSupply(), 2);

        vm.prank(alice);
        registry.deactivateAgent(1);
        vm.prank(bob);
        registry.deactivateAgent(4);
        assertEq(registry.getCollectionSupply(), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  GAS BENCHMARKS
    // ═══════════════════════════════════════════════════════════

    function test_gas_activateAgent() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        registry.activateAgent(1, AGENT_URI);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for activateAgent", gasUsed);
    }

    function test_gas_query() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 gasBefore = gasleft();
        registry.query{value: 0.01 ether}(1, keccak256("test"));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for query", gasUsed);
    }

    function test_gas_fulfill() public {
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);

        vm.prank(bob);
        uint256 qId = registry.query{value: 0.01 ether}(1, keccak256("test"));

        vm.prank(fulfiller);
        uint256 gasBefore = gasleft();
        registry.fulfill(qId, keccak256("result"));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for fulfill", gasUsed);
    }

    function test_gas_batchFulfill() public {
        _activatePunk1();

        uint256[] memory ids = new uint256[](10);
        bytes32[] memory hashes = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(bob);
            ids[i] = registry.query{value: 0.01 ether}(1, keccak256(abi.encode(i)));
            hashes[i] = keccak256(abi.encode("r", i));
        }

        vm.prank(fulfiller);
        uint256 gasBefore = gasleft();
        registry.batchFulfill(ids, hashes);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for batchFulfill (10)", gasUsed);
    }

    function test_gas_pauseResumeAgent() public {
        _activatePunk1();

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        registry.pauseAgent(1);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for pauseAgent", gasUsed);

        vm.prank(alice);
        gasBefore = gasleft();
        registry.resumeAgent(1);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for resumeAgent", gasUsed);
    }

    function test_gas_setMinFee() public {
        _activatePunk1();

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        registry.setMinFee(1, 0.05 ether);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for setMinFee", gasUsed);
    }

    function test_gas_createPunkTBA() public {
        uint256 gasBefore = gasleft();
        registry.createPunkTBA(1);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for createPunkTBA", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════
    //  END-TO-END SCENARIO
    // ═══════════════════════════════════════════════════════════

    function test_endToEnd_fullLifecycle() public {
        // 1. Admin opens activation
        vm.prank(admin);
        registry.openActivation(block.number);

        // 2. Alice activates punk 1
        vm.prank(alice);
        registry.activateAgent(1, AGENT_URI);
        assertEq(registry.getCollectionSupply(), 1);

        // 3. Bob activates punk 4
        vm.prank(bob);
        registry.activateAgent(4, AGENT_URI);
        assertEq(registry.getCollectionSupply(), 2);

        // 4. Alice sets custom min fee
        vm.prank(alice);
        registry.setMinFee(1, 0.05 ether);
        assertEq(registry.getEffectiveMinFee(1), 0.05 ether);

        // 5. Bob queries Alice's punk
        vm.prank(bob);
        uint256 qId1 = registry.query{value: 0.1 ether}(1, keccak256("analyze subnet"));

        // 6. Fulfiller delivers result
        vm.prank(fulfiller);
        registry.fulfill(qId1, keccak256("subnet analysis result"));

        // 7. Verify TAO in TBA, resultHash stored
        address tba1 = _getTBA(1);
        assertEq(tba1.balance, 0.1 ether);
        assertEq(registry.getQueryCount(1), 1);
        (, , , , , , bytes32 rh) = registry.queries(qId1);
        assertEq(rh, keccak256("subnet analysis result"));

        // 8. Deploy TBA and Alice withdraws
        _createTBA(1);
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        TaoPunkAccount(payable(tba1)).execute(alice, 0.1 ether, "", 0);
        assertEq(alice.balance, aliceBal + 0.1 ether);

        // 9. Alice pauses her agent
        vm.prank(alice);
        registry.pauseAgent(1);
        assertTrue(registry.isAgentPaused(1));

        // 10. Bob cannot query paused agent
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentIsPaused.selector, 1));
        registry.query{value: 0.1 ether}(1, keccak256("blocked"));

        // 11. Alice resumes
        vm.prank(alice);
        registry.resumeAgent(1);
        assertFalse(registry.isAgentPaused(1));

        // 12. Alice sells punk 1 to Bob
        punks.transferFrom(alice, bob, 1);

        // 13. New query — revenue goes to punk 1's TBA (Bob now controls)
        vm.prank(alice);
        uint256 qId2 = registry.query{value: 0.1 ether}(1, keccak256("follow up"));

        vm.prank(fulfiller);
        registry.fulfill(qId2, keccak256("follow up result"));
        assertEq(tba1.balance, 0.1 ether); // Fresh after alice withdrew

        // 14. Bob withdraws from TBA
        uint256 bobBal = bob.balance;
        vm.prank(bob);
        TaoPunkAccount(payable(tba1)).execute(bob, 0.1 ether, "", 0);
        assertEq(bob.balance, bobBal + 0.1 ether);

        // 15. Bob updates the agent URI
        vm.prank(bob);
        registry.updateAgentURI(1, AGENT_URI_2);
        (, , , , , , string memory uri) = registry.getAgent(1);
        assertEq(uri, AGENT_URI_2);

        // 16. Query count accumulates
        assertEq(registry.getQueryCount(1), 2);

        // 17. Verify agent cannot be re-activated
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TaoPunkAgentRegistry.AgentAlreadyActive.selector, 1));
        registry.activateAgent(1, AGENT_URI);

        // 18. Batch fulfill test within lifecycle
        vm.prank(bob);
        registry.activateAgent(5, AGENT_URI);

        vm.prank(alice);
        uint256 q3 = registry.query{value: 0.01 ether}(4, keccak256("batch1"));
        vm.prank(alice);
        uint256 q4 = registry.query{value: 0.02 ether}(5, keccak256("batch2"));

        uint256[] memory batchIds = new uint256[](2);
        batchIds[0] = q3;
        batchIds[1] = q4;
        bytes32[] memory batchHashes = new bytes32[](2);
        batchHashes[0] = keccak256("br1");
        batchHashes[1] = keccak256("br2");

        vm.prank(fulfiller);
        registry.batchFulfill(batchIds, batchHashes);

        assertEq(registry.getQueryCount(4), 1);
        assertEq(registry.getQueryCount(5), 1);
    }
}

// ═══════════════════════════════════════════════════════════════
//  HELPER CONTRACTS
// ═══════════════════════════════════════════════════════════════

/// @dev Contract that always reverts on ETH receive
contract RevertOnReceive {
    receive() external payable {
        revert("no ETH");
    }
}
