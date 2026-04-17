// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "erc721a/ERC721A.sol";
import "erc721a/extensions/ERC721ABurnable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TaoPunksV2 — Community Takeover contract
/// @notice Immutable metadata, 0% royalties, airdrop-only distribution
contract TaoPunksV2 is ERC721A, ERC721ABurnable, Ownable2Step, ReentrancyGuard {

    uint256 public constant MAX_SUPPLY = 3333;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Set once in constructor. No setter function exists.
    string private _baseTokenURI;

    /// @dev Once true, no more minting is possible — ever.
    bool public airdropFinalized;

    error AirdropAlreadyFinalized();
    error ExceedsMaxSupply();
    error NotTokenOwner();

    event AirdropFinalized(uint256 totalMinted);
    event BaseURILocked(string baseURI);

    constructor(
        address _owner,
        string memory baseURI_
    ) ERC721A("TAO Punks", "TAOPUNK") Ownable(_owner) {
        _baseTokenURI = baseURI_;
        emit BaseURILocked(baseURI_);
    }

    // ══════════════════════════════════════════════════════════════
    //  AIRDROP (owner-only, one-time)
    // ══════════════════════════════════════════════════════════════

    /// @notice Mint tokens to recipients in order. recipients[i] receives the next sequential token ID.
    ///         Call in batches (e.g. 100 at a time) to fit within gas limits.
    /// @param recipients Ordered array of addresses. Use BURN_ADDRESS for team tokens.
    function airdropBatch(address[] calldata recipients) external onlyOwner nonReentrant {
        if (airdropFinalized) revert AirdropAlreadyFinalized();
        if (_totalMinted() + recipients.length > MAX_SUPPLY) revert ExceedsMaxSupply();

        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], 1);
        }
    }

    /// @notice Permanently lock minting. Call after airdrop is complete.
    function finalizeAirdrop() external onlyOwner {
        if (airdropFinalized) revert AirdropAlreadyFinalized();
        airdropFinalized = true;
        emit AirdropFinalized(_totalMinted());
    }

    // ══════════════════════════════════════════════════════════════
    //  SAFETY OVERRIDES
    // ══════════════════════════════════════════════════════════════

    /// @dev Disable renounceOwnership to prevent accidental lockout.
    function renounceOwnership() public pure override {
        revert("Disabled");
    }

    // ══════════════════════════════════════════════════════════════
    //  METADATA (immutable)
    // ══════════════════════════════════════════════════════════════

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ══════════════════════════════════════════════════════════════

    function totalBurned() external view returns (uint256) {
        return _totalBurned();
    }

    function totalMinted() external view returns (uint256) {
        return _totalMinted();
    }

    /// @dev No ERC2981. supportsInterface only reports ERC721 + ERC721Metadata.
    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721A, IERC721A) returns (bool)
    {
        return ERC721A.supportsInterface(interfaceId);
    }
}
