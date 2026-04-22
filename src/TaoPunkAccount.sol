// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC6551Account.sol";
import "./interfaces/IERC6551Executable.sol";

/// @title TaoPunkAccount — ERC-6551 Token Bound Account for TAO Punks
/// @notice Minimal TBA. The punk IS the wallet.
///         Owner = TaoPunksV2.ownerOf(tokenId) — dynamic, follows NFT transfers.
///         Supports CALL operations only (no DELEGATECALL/CREATE for security).
contract TaoPunkAccount is IERC6551Account, IERC6551Executable {
    uint256 private _state;

    error NotAuthorized();
    error OnlyCallOperation();
    error ExecutionFailed();

    /// @notice Accept TAO deposits
    receive() external payable override {}

    /// @notice Execute a call from this account. Only the current punk owner can call.
    function execute(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external payable returns (bytes memory result) {
        if (!_isValidSigner(msg.sender)) revert NotAuthorized();
        if (operation != 0) revert OnlyCallOperation();

        ++_state;

        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) revert ExecutionFailed();
    }

    /// @notice Returns the token this account is bound to
    function token()
        public
        view
        returns (uint256 chainId, address tokenContract, uint256 tokenId)
    {
        bytes memory footer = new bytes(96);
        assembly {
            // ERC-1167 proxy appends: salt(32) | chainId(32) | tokenContract(32) | tokenId(32)
            // Total appended = 128 bytes. Last 96 bytes = chainId + tokenContract + tokenId.
            extcodecopy(address(), add(footer, 0x20), sub(extcodesize(address()), 96), 96)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }

    /// @notice Monotonically increasing state counter
    function state() external view returns (uint256) {
        return _state;
    }

    /// @notice Check if a signer is valid for this account
    function isValidSigner(address signer, bytes calldata)
        external
        view
        returns (bytes4 magicValue)
    {
        if (_isValidSigner(signer)) {
            return IERC6551Account.isValidSigner.selector;
        }
        return bytes4(0);
    }

    /// @notice ERC-165 support
    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC6551Executable).interfaceId ||
            interfaceId == 0x01ffc9a7; // IERC165
    }

    /// @dev Current punk owner is the valid signer
    function _isValidSigner(address signer) internal view returns (bool) {
        (, address tokenContract, uint256 tokenId) = token();
        (bool ok, bytes memory result) = tokenContract.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );
        if (!ok || result.length < 32) return false;
        return signer == abi.decode(result, (address));
    }
}
