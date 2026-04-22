// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IERC6551Registry.sol";

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
///         Revenue goes directly to each punk's ERC-6551 Token Bound Account — the punk IS the wallet.
///         First ERC-8004 + ERC-8041 + ERC-6551 deployment on Bittensor EVM (Chain 964).
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
    uint256 public constant MIN_QUERY_FEE = 0.0001 ether; // 0.0001 TAO floor
    uint256 public constant MAX_QUERY_FEE = 1 ether;      // 1 TAO ceiling
    uint256 public constant MAX_BATCH_SIZE = 50;
    bytes32 public constant TBA_SALT = bytes32(0);         // One TBA per punk

    // ══════════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The TaoPunksV2 ERC-721 contract
    IERC721Minimal public immutable punks;

    /// @notice ERC-6551 registry for Token Bound Account address computation
    IERC6551Registry public immutable tbaRegistry;

    /// @notice TaoPunkAccount implementation contract
    address public immutable tbaImplementation;

    // ══════════════════════════════════════════════════════════════
    //  AGENT STORAGE
    // ══════════════════════════════════════════════════════════════

    struct AgentRecord {
        bool active;            // Has this punk been activated?
        bool paused;            // Is the agent paused? (rejects new queries)
        uint64 activatedAt;     // Timestamp of activation
        uint64 queryCount;      // Total queries fulfilled
        uint64 lastQueryAt;     // Timestamp of last fulfilled query
        uint128 minFee;         // Holder-set minimum fee (0 = use global MIN_QUERY_FEE)
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
        bytes32 resultHash;     // keccak256 of result data (set on fulfill)
    }

    /// @notice queryId → Query
    mapping(uint256 => Query) public queries;

    /// @notice Auto-incrementing query ID (starts at 1 so ID 0 = does not exist)
    uint256 public nextQueryId = 1;

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
    event AgentPaused(uint256 indexed punkId);
    event AgentResumed(uint256 indexed punkId);
    event AgentMinFeeUpdated(uint256 indexed punkId, uint128 oldFee, uint128 newFee);
    event AgentDeactivated(uint256 indexed punkId, address indexed owner);

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
    event FeeTransferredToTBA(uint256 indexed queryId, uint256 indexed punkId, address indexed tba, uint256 amount);
    event OwnerQuery(uint256 indexed queryId, uint256 indexed punkId, address indexed owner, bytes32 inputHash);

    event ActivationOpened(uint256 startBlock);
    event ActivationClosed();
    event QueryExpiryUpdated(uint256 oldExpiry, uint256 newExpiry);

    // ══════════════════════════════════════════════════════════════
    //  ERRORS
    // ══════════════════════════════════════════════════════════════

    error NotPunkOwner(uint256 punkId);
    error AgentAlreadyActive(uint256 punkId);
    error AgentNotActive(uint256 punkId);
    error AgentIsPaused(uint256 punkId);
    error AgentNotPaused(uint256 punkId);
    error ActivationNotOpen();
    error InvalidURI();
    error InvalidPunkId(uint256 punkId);
    error InvalidFee();
    error InsufficientFee(uint256 sent, uint256 minimum);
    error ExcessiveFee(uint256 sent, uint256 maximum);
    error QueryNotPending(uint256 queryId);
    error QueryNotExpired(uint256 queryId);
    error InvalidExpiry();
    error InvalidBatchSize();
    error BatchLengthMismatch();
    error TransferFailed(address to, uint256 amount);
    error TBATransferFailed(uint256 punkId, address tba, uint256 amount);
    error QueryDoesNotExist(uint256 queryId);
    error ZeroAddress();

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _punks TaoPunksV2 contract address
    /// @param _admin Initial admin (receives DEFAULT_ADMIN_ROLE)
    /// @param _tbaRegistry ERC-6551 registry contract address
    /// @param _tbaImplementation TaoPunkAccount implementation address
    constructor(
        address _punks,
        address _admin,
        address _tbaRegistry,
        address _tbaImplementation
    ) {
        if (_punks == address(0) || _admin == address(0)) revert ZeroAddress();
        if (_tbaRegistry == address(0) || _tbaImplementation == address(0)) revert ZeroAddress();

        punks = IERC721Minimal(_punks);
        tbaRegistry = IERC6551Registry(_tbaRegistry);
        tbaImplementation = _tbaImplementation;

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
            paused: false,
            activatedAt: uint64(block.timestamp),
            queryCount: 0,
            lastQueryAt: 0,
            minFee: 0,
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

    /// @notice Deactivate your agent. Resets all stats, URI, minFee, and paused state.
    ///         The punk can be re-activated later via activateAgent() with a fresh start.
    ///         TAO already in the punk's TBA is unaffected.
    /// @param punkId The punk to deactivate
    function deactivateAgent(uint256 punkId)
        external
        onlyPunkOwner(punkId)
        onlyActivePunk(punkId)
    {
        delete _agents[punkId]; // Resets entire struct to defaults (active=false, all zeros)

        unchecked { _currentSupply--; }

        emit AgentDeactivated(punkId, msg.sender);
    }

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

    /// @notice Set minimum query fee for your agent. 0 = use global MIN_QUERY_FEE.
    /// @param punkId The punk to configure
    /// @param newMinFee Minimum fee in wei (must be within global bounds or 0)
    function setMinFee(uint256 punkId, uint128 newMinFee)
        external
        onlyPunkOwner(punkId)
        onlyActivePunk(punkId)
    {
        if (newMinFee != 0 && (newMinFee < MIN_QUERY_FEE || newMinFee > MAX_QUERY_FEE)) {
            revert InvalidFee();
        }
        uint128 old = _agents[punkId].minFee;
        _agents[punkId].minFee = newMinFee;
        emit AgentMinFeeUpdated(punkId, old, newMinFee);
    }

    /// @notice Pause your agent. Rejects new queries while paused.
    function pauseAgent(uint256 punkId)
        external
        onlyPunkOwner(punkId)
        onlyActivePunk(punkId)
    {
        if (_agents[punkId].paused) revert AgentIsPaused(punkId);
        _agents[punkId].paused = true;
        emit AgentPaused(punkId);
    }

    /// @notice Resume a paused agent. Accepts new queries again.
    function resumeAgent(uint256 punkId)
        external
        onlyPunkOwner(punkId)
        onlyActivePunk(punkId)
    {
        if (!_agents[punkId].paused) revert AgentNotPaused(punkId);
        _agents[punkId].paused = false;
        emit AgentResumed(punkId);
    }

    // ══════════════════════════════════════════════════════════════
    //  QUERY / FULFILL (Pay-Per-Call)
    // ══════════════════════════════════════════════════════════════

    /// @notice Submit a query to a punk agent. Caller pays TAO, held in escrow.
    ///         Punk owners can query their own agent for free (0 TAO).
    /// @param punkId The punk to query
    /// @param inputHash keccak256 hash of the input data (full data sent off-chain to relay)
    function query(uint256 punkId, bytes32 inputHash)
        external
        payable
        nonReentrant
        onlyActivePunk(punkId)
        returns (uint256 queryId)
    {
        AgentRecord storage agent = _agents[punkId];
        if (agent.paused) revert AgentIsPaused(punkId);

        bool isOwner = punks.ownerOf(punkId) == msg.sender;

        if (!isOwner) {
            // Enforce holder-set minFee (falls back to global MIN_QUERY_FEE if 0)
            uint256 effectiveMin = agent.minFee > 0 ? uint256(agent.minFee) : MIN_QUERY_FEE;
            if (msg.value < effectiveMin) revert InsufficientFee(msg.value, effectiveMin);
            if (msg.value > MAX_QUERY_FEE) revert ExcessiveFee(msg.value, MAX_QUERY_FEE);
        }

        queryId = nextQueryId++;

        queries[queryId] = Query({
            punkId: punkId,
            caller: msg.sender,
            fee: uint128(msg.value), // 0 for owner queries
            status: QueryStatus.Pending,
            createdAt: uint64(block.timestamp),
            inputHash: inputHash,
            resultHash: bytes32(0)
        });

        if (isOwner) {
            emit OwnerQuery(queryId, punkId, msg.sender, inputHash);
        } else {
            emit QueryRequested(queryId, punkId, msg.sender, uint128(msg.value), inputHash);
        }
    }

    /// @notice Fulfill a pending query. TAO goes directly to the punk's Token Bound Account.
    /// @param queryId The query to fulfill
    /// @param resultHash keccak256 hash of the result data (full result delivered off-chain)
    function fulfill(uint256 queryId, bytes32 resultHash)
        external
        onlyRole(FULFILLER_ROLE)
        nonReentrant
    {
        _fulfill(queryId, resultHash);
    }

    /// @notice Fulfill multiple queries in one transaction. Saves gas for the relay.
    /// @param queryIds Array of query IDs to fulfill
    /// @param resultHashes Array of result hashes (must match queryIds length)
    function batchFulfill(uint256[] calldata queryIds, bytes32[] calldata resultHashes)
        external
        onlyRole(FULFILLER_ROLE)
        nonReentrant
    {
        uint256 len = queryIds.length;
        if (len == 0 || len > MAX_BATCH_SIZE) revert InvalidBatchSize();
        if (len != resultHashes.length) revert BatchLengthMismatch();

        for (uint256 i; i < len;) {
            _fulfill(queryIds[i], resultHashes[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Refund an expired query to the caller
    /// @param queryId The query to refund
    function refundExpiredQuery(uint256 queryId) external nonReentrant {
        Query storage q = queries[queryId];
        if (q.caller == address(0)) revert QueryDoesNotExist(queryId);
        if (q.status != QueryStatus.Pending) revert QueryNotPending(queryId);
        if (block.timestamp < q.createdAt + queryExpiry) revert QueryNotExpired(queryId);

        q.status = QueryStatus.Expired;
        _safeTransfer(q.caller, q.fee);

        emit QueryRefunded(queryId);
    }

    // ══════════════════════════════════════════════════════════════
    //  TOKEN BOUND ACCOUNTS (ERC-6551)
    // ══════════════════════════════════════════════════════════════

    /// @notice Compute the deterministic TBA address for a punk.
    ///         Address is valid whether or not the TBA has been deployed.
    function getPunkTBA(uint256 punkId) external view returns (address) {
        return tbaRegistry.account(
            tbaImplementation, TBA_SALT, block.chainid, address(punks), punkId
        );
    }

    /// @notice Deploy the TBA for a punk (permissionless, idempotent).
    ///         Returns the TBA address (same whether newly deployed or already exists).
    function createPunkTBA(uint256 punkId) external returns (address) {
        return tbaRegistry.createAccount(
            tbaImplementation, TBA_SALT, block.chainid, address(punks), punkId
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Get full agent record for a punk
    function getAgent(uint256 punkId) external view returns (
        bool active,
        bool paused,
        uint64 activatedAt,
        uint64 queryCount,
        uint64 lastQueryAt,
        uint128 minFee,
        string memory agentURI
    ) {
        AgentRecord storage a = _agents[punkId];
        return (a.active, a.paused, a.activatedAt, a.queryCount, a.lastQueryAt, a.minFee, a.agentURI);
    }

    /// @notice Check if a punk has an active agent
    function isAgentActive(uint256 punkId) external view returns (bool) {
        return _agents[punkId].active;
    }

    /// @notice Check if an agent is paused
    function isAgentPaused(uint256 punkId) external view returns (bool) {
        return _agents[punkId].paused;
    }

    /// @notice Get the effective minimum fee for querying an agent
    function getEffectiveMinFee(uint256 punkId) external view returns (uint256) {
        uint128 holderMin = _agents[punkId].minFee;
        return holderMin > 0 ? uint256(holderMin) : MIN_QUERY_FEE;
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

    /// @dev Internal fulfill logic shared by fulfill() and batchFulfill().
    ///      Sends TAO directly to the punk's Token Bound Account (push-based).
    function _fulfill(uint256 queryId, bytes32 resultHash) internal {
        Query storage q = queries[queryId];
        if (q.caller == address(0)) revert QueryDoesNotExist(queryId);
        if (q.status != QueryStatus.Pending) revert QueryNotPending(queryId);

        q.status = QueryStatus.Fulfilled;
        q.resultHash = resultHash;

        // Update agent stats
        AgentRecord storage agent = _agents[q.punkId];
        unchecked { agent.queryCount++; }
        agent.lastQueryAt = uint64(block.timestamp);

        // 100% to punk's TBA — push-based (TAO leaves registry immediately)
        if (q.fee > 0) {
            address tba = tbaRegistry.account(
                tbaImplementation, TBA_SALT, block.chainid, address(punks), q.punkId
            );
            (bool ok, ) = tba.call{value: q.fee}("");
            if (!ok) revert TBATransferFailed(q.punkId, tba, q.fee);
            emit FeeTransferredToTBA(queryId, q.punkId, tba, q.fee);
        }

        emit QueryFulfilled(queryId, q.punkId, resultHash);
    }

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
