// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IERC8041Collection — Fixed-Supply Agent NFT Collections
/// @notice Minimal interface per EIP-8041 (Draft)
interface IERC8041Collection {
    event CollectionUpdated(uint256 maxSupply, uint256 startBlock, bool open);
    event AgentMinted(uint256 indexed agentId, uint256 mintNumber, address indexed owner);

    function getAgentMintNumber(uint256 agentId) external view returns (uint256 mintNumber);
    function getCollectionSupply() external view returns (uint256 currentSupply);
}

/// @title IERC721Minimal — Read-only interface for TaoPunksV2
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
}

/// @title TaoPunkAgentRegistry
/// @notice Binds ERC-8004 agent identities to TAO Punks V2 NFTs using ERC-8041 fixed-supply logic.
///         Each punk can activate exactly one agent. Agent control follows punk ownership automatically.
///         First ERC-8004 + ERC-8041 deployment on Bittensor EVM (Chain 964).
/// @dev    The punk contract (TaoPunksV2) is immutable and untouched. This contract reads ownerOf()
///         to derive agent control. No separate agent NFT is created — the punk IS the identity.
contract TaoPunkAgentRegistry is IERC8041Collection, AccessControl, ReentrancyGuard {

    // ══════════════════════════════════════════════════════════════
    //  ROLES
    // ══════════════════════════════════════════════════════════════

    /// @notice Can fulfill queries and update relay parameters
    bytes32 public constant FULFILLER_ROLE = keccak256("FULFILLER_ROLE");

    /// @notice Can adjust protocol parameters (fees, cooldowns, etc.)
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    // ══════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ══════════════════════════════════════════════════════════════

    uint256 public constant MAX_SUPPLY = 3333;
    uint256 public constant MIN_QUERY_FEE = 0.0001 ether; // 0.0001 TAO minimum
    uint256 public constant MAX_QUERY_FEE = 1 ether;      // 1 TAO maximum

    // ══════════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The TaoPunksV2 ERC-721 contract
    IERC721Minimal public immutable punks;

    /// @notice Protocol treasury address
    address public treasury;

    // ══════════════════════════════════════════════════════════════
    //  AGENT STORAGE
    // ══════════════════════════════════════════════════════════════

    struct AgentRecord {
        bool active;            // Has this punk been activated?
        uint64 activatedAt;     // Timestamp of activation
        uint64 queryCount;      // Total queries fulfilled
        uint64 lastQueryAt;     // Timestamp of last fulfilled query
        string agentURI;        // ERC-8004 metadata URI (IPFS)
    }

    /// @notice punkId → agent record
    mapping(uint256 => AgentRecord) private _agents;

    /// @notice Total activated agents (ERC-8041 currentSupply)
    uint256 private _currentSupply;

    /// @notice Whether activation is open
    bool public activationOpen;

    /// @notice Block number when activation opens (ERC-8041 startBlock)
    uint256 public startBlock;

    // ══════════════════════════════════════════════════════════════
    //  QUERY STORAGE
    // ══════════════════════════════════════════════════════════════

    enum QueryStatus { Pending, Fulfilled, Refunded, Expired }

    struct Query {
        uint256 punkId;
        address caller;
        uint128 fee;
        QueryStatus status;
        uint64 createdAt;
        bytes32 inputHash;      // keccak256 of input data (stored off-chain)
    }

    /// @notice Claimable balances — holders call claim() to withdraw earned TAO
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice queryId → Query
    mapping(uint256 => Query) public queries;

    /// @notice Auto-incrementing query ID
    uint256 public nextQueryId;

    /// @notice Query expiry duration (default 1 hour)
    uint256 public queryExpiry = 1 hours;

    // ══════════════════════════════════════════════════════════════
    //  ERC-8004 METADATA STORAGE
    // ══════════════════════════════════════════════════════════════

    /// @notice ERC-8004 agent metadata: agentId → key → value
    mapping(uint256 => mapping(string => bytes)) private _agentMetadata;

    // ══════════════════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════════════════

    event AgentActivated(uint256 indexed punkId, address indexed owner, string agentURI);
    event AgentURIUpdated(uint256 indexed punkId, string newURI);
    event AgentMetadataSet(uint256 indexed punkId, string key, bytes value);

    event QueryRequested(
        uint256 indexed queryId,
        uint256 indexed punkId,
        address indexed caller,
        uint128 fee,
        bytes32 inputHash
    );

    event QueryFulfilled(
        uint256 indexed queryId,
        uint256 indexed punkId,
        bytes32 resultHash
    );

    event QueryRefunded(uint256 indexed queryId);
    event Claimed(address indexed account, uint256 amount);

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ActivationOpened(uint256 startBlock);
    event ActivationClosed();
    event QueryExpiryUpdated(uint256 oldExpiry, uint256 newExpiry);

    // ══════════════════════════════════════════════════════════════
    //  ERRORS
    // ══════════════════════════════════════════════════════════════

    error NotPunkOwner(uint256 punkId);
    error AgentAlreadyActive(uint256 punkId);
    error AgentNotActive(uint256 punkId);
    error ActivationNotOpen();
    error InvalidURI();
    error InvalidPunkId(uint256 punkId);
    error InsufficientFee(uint256 sent, uint256 minimum);
    error ExcessiveFee(uint256 sent, uint256 maximum);
    error QueryNotPending(uint256 queryId);
    error QueryNotExpired(uint256 queryId);
    error InvalidTreasury();
    error InvalidExpiry();
    error TransferFailed(address to, uint256 amount);
    error QueryDoesNotExist(uint256 queryId);
    error NothingToClaim();

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _punks TaoPunksV2 contract address
    /// @param _treasury Protocol treasury address
    /// @param _admin Initial admin (receives DEFAULT_ADMIN_ROLE)
    constructor(address _punks, address _treasury, address _admin) {
        if (_punks == address(0) || _treasury == address(0) || _admin == address(0)) {
            revert InvalidTreasury();
        }

        punks = IERC721Minimal(_punks);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNOR_ROLE, _admin);
    }

    // ══════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier onlyPunkOwner(uint256 punkId) {
        if (punks.ownerOf(punkId) != msg.sender) revert NotPunkOwner(punkId);
        _;
    }

    modifier onlyActivePunk(uint256 punkId) {
        if (!_agents[punkId].active) revert AgentNotActive(punkId);
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //  ACTIVATION (ERC-8041 Minting)
    // ══════════════════════════════════════════════════════════════

    /// @notice Activate an agent for your punk. One punk = one agent, forever bound.
    /// @param punkId The TAO Punk token ID (1-3333)
    /// @param agentURI IPFS URI pointing to ERC-8004 agent metadata
    function activateAgent(uint256 punkId, string calldata agentURI) external onlyPunkOwner(punkId) {
        if (!activationOpen) revert ActivationNotOpen();
        if (block.number < startBlock) revert ActivationNotOpen();
        if (punkId == 0 || punkId > MAX_SUPPLY) revert InvalidPunkId(punkId);
        if (_agents[punkId].active) revert AgentAlreadyActive(punkId);
        if (bytes(agentURI).length == 0) revert InvalidURI();

        _agents[punkId] = AgentRecord({
            active: true,
            activatedAt: uint64(block.timestamp),
            queryCount: 0,
            lastQueryAt: 0,
            agentURI: agentURI
        });

        unchecked { _currentSupply++; }

        // ERC-8041 events
        emit AgentMinted(punkId, punkId, msg.sender); // mintNumber == punkId (1:1 mapping)
        emit AgentActivated(punkId, msg.sender, agentURI);
    }

    // ══════════════════════════════════════════════════════════════
    //  AGENT MANAGEMENT (owner of punk controls agent)
    // ══════════════════════════════════════════════════════════════

    /// @notice Update agent metadata URI (only punk owner)
    function updateAgentURI(uint256 punkId, string calldata newURI)
        external
        onlyPunkOwner(punkId)
        onlyActivePunk(punkId)
    {
        if (bytes(newURI).length == 0) revert InvalidURI();
        _agents[punkId].agentURI = newURI;
        emit AgentURIUpdated(punkId, newURI);
    }

    /// @notice Set ERC-8004 metadata key-value pair for an agent
    function setAgentMetadata(uint256 punkId, string calldata key, bytes calldata value)
        external
        onlyPunkOwner(punkId)
        onlyActivePunk(punkId)
    {
        _agentMetadata[punkId][key] = value;
        emit AgentMetadataSet(punkId, key, value);
    }

    // ══════════════════════════════════════════════════════════════
    //  QUERY / FULFILL (Pay-Per-Call)
    // ══════════════════════════════════════════════════════════════

    /// @notice Submit a query to a punk agent. Caller pays TAO, held in escrow.
    /// @param punkId The punk to query
    /// @param inputHash keccak256 hash of the input data (full data sent off-chain to relay)
    function query(uint256 punkId, bytes32 inputHash)
        external
        payable
        nonReentrant
        onlyActivePunk(punkId)
        returns (uint256 queryId)
    {
        if (msg.value < MIN_QUERY_FEE) revert InsufficientFee(msg.value, MIN_QUERY_FEE);
        if (msg.value > MAX_QUERY_FEE) revert ExcessiveFee(msg.value, MAX_QUERY_FEE);

        queryId = nextQueryId++;

        queries[queryId] = Query({
            punkId: punkId,
            caller: msg.sender,
            fee: uint128(msg.value),
            status: QueryStatus.Pending,
            createdAt: uint64(block.timestamp),
            inputHash: inputHash
        });

        emit QueryRequested(queryId, punkId, msg.sender, uint128(msg.value), inputHash);
    }

    /// @notice Fulfill a pending query with results. Credits 100% of fee to punk holder's claimable balance.
    /// @param queryId The query to fulfill
    /// @param resultHash keccak256 hash of the result data (full result delivered off-chain)
    function fulfill(uint256 queryId, bytes32 resultHash)
        external
        onlyRole(FULFILLER_ROLE)
    {
        Query storage q = queries[queryId];
        if (q.fee == 0 && q.caller == address(0)) revert QueryDoesNotExist(queryId);
        if (q.status != QueryStatus.Pending) revert QueryNotPending(queryId);

        q.status = QueryStatus.Fulfilled;

        // Update agent stats
        AgentRecord storage agent = _agents[q.punkId];
        unchecked { agent.queryCount++; }
        agent.lastQueryAt = uint64(block.timestamp);

        // 100% to current punk holder — pull-based (no external call here)
        address holder = punks.ownerOf(q.punkId);
        pendingWithdrawals[holder] += q.fee;

        emit QueryFulfilled(queryId, q.punkId, resultHash);
    }

    /// @notice Claim all earned TAO. Holders call this to withdraw their accumulated fees.
    function claim() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToClaim();

        pendingWithdrawals[msg.sender] = 0;
        _safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    /// @notice Refund an expired query to the caller
    /// @param queryId The query to refund
    function refundExpiredQuery(uint256 queryId) external nonReentrant {
        Query storage q = queries[queryId];
        if (q.fee == 0 && q.caller == address(0)) revert QueryDoesNotExist(queryId);
        if (q.status != QueryStatus.Pending) revert QueryNotPending(queryId);
        if (block.timestamp < q.createdAt + queryExpiry) revert QueryNotExpired(queryId);

        q.status = QueryStatus.Expired;
        _safeTransfer(q.caller, q.fee);

        emit QueryRefunded(queryId);
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Get full agent record for a punk
    function getAgent(uint256 punkId) external view returns (
        bool active,
        uint64 activatedAt,
        uint64 queryCount,
        uint64 lastQueryAt,
        string memory agentURI
    ) {
        AgentRecord storage a = _agents[punkId];
        return (a.active, a.activatedAt, a.queryCount, a.lastQueryAt, a.agentURI);
    }

    /// @notice Check if a punk has an active agent
    function isAgentActive(uint256 punkId) external view returns (bool) {
        return _agents[punkId].active;
    }

    /// @notice Get the controller (current punk owner) for an agent
    function getController(uint256 punkId) external view returns (address) {
        return punks.ownerOf(punkId);
    }

    /// @notice Get the agent ID for a punk (1:1 mapping, agentId == punkId)
    function getAgentForPunk(uint256 punkId) external view returns (uint256) {
        if (!_agents[punkId].active) revert AgentNotActive(punkId);
        return punkId; // agentId == punkId in this binding model
    }

    /// @notice Get ERC-8004 metadata for an agent
    function getAgentMetadata(uint256 punkId, string calldata key) external view returns (bytes memory) {
        return _agentMetadata[punkId][key];
    }

    /// @notice Get query count for a punk agent
    function getQueryCount(uint256 punkId) external view returns (uint64) {
        return _agents[punkId].queryCount;
    }

    // ══════════════════════════════════════════════════════════════
    //  ERC-8041 (Fixed-Supply Collection)
    // ══════════════════════════════════════════════════════════════

    /// @notice Returns the mint number for an agent. mintNumber == punkId.
    function getAgentMintNumber(uint256 agentId) external view override returns (uint256) {
        if (!_agents[agentId].active) return 0; // 0 = not in collection
        return agentId; // mint number IS the punk ID
    }

    /// @notice Returns total activated agents
    function getCollectionSupply() external view override returns (uint256) {
        return _currentSupply;
    }

    /// @notice Returns max supply (always 3333)
    function getMaxSupply() external pure returns (uint256) {
        return MAX_SUPPLY;
    }

    // ══════════════════════════════════════════════════════════════
    //  GOVERNANCE
    // ══════════════════════════════════════════════════════════════

    /// @notice Open activation for punk holders
    function openActivation(uint256 _startBlock) external onlyRole(GOVERNOR_ROLE) {
        activationOpen = true;
        startBlock = _startBlock;
        emit CollectionUpdated(MAX_SUPPLY, _startBlock, true);
        emit ActivationOpened(_startBlock);
    }

    /// @notice Close activation (no new agents can be activated)
    function closeActivation() external onlyRole(GOVERNOR_ROLE) {
        activationOpen = false;
        emit CollectionUpdated(MAX_SUPPLY, startBlock, false);
        emit ActivationClosed();
    }

    /// @notice Update treasury address
    function setTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        if (newTreasury == address(0)) revert InvalidTreasury();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /// @notice Update query expiry duration
    function setQueryExpiry(uint256 newExpiry) external onlyRole(GOVERNOR_ROLE) {
        if (newExpiry < 5 minutes || newExpiry > 24 hours) revert InvalidExpiry();
        uint256 old = queryExpiry;
        queryExpiry = newExpiry;
        emit QueryExpiryUpdated(old, newExpiry);
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════════════

    /// @dev Safe TAO transfer with error handling
    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERFACE SUPPORT
    // ══════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl) returns (bool)
    {
        return
            interfaceId == type(IERC8041Collection).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
