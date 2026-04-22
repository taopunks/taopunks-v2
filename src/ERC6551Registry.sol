// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC6551Registry.sol";

/// @title ERC-6551 Registry
/// @notice Deploys and computes deterministic Token Bound Account addresses.
///         Reference implementation adapted for Bittensor EVM (Chain 964).
contract ERC6551Registry is IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address) {
        assembly {
            let ptr := mload(0x40)

            // ERC-1167 minimal proxy init code with appended immutable data
            // Preamble (10 bytes): deploys runtime code of size 0xad (173 bytes)
            // Runtime = proxy(45 bytes) + appended(128 bytes) = 173
            // Init code total = 10 + 173 = 183 = 0xb7

            // 10 bytes preamble + 10 bytes proxy prefix
            mstore(ptr, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            // 20 bytes implementation address
            mstore(add(ptr, 0x14), shl(96, implementation))
            // 15 bytes proxy suffix
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            // Appended immutable data (128 bytes = 4 × 32):
            mstore(add(ptr, 0x37), salt)            // 32 bytes salt
            mstore(add(ptr, 0x57), chainId)          // 32 bytes chainId
            mstore(add(ptr, 0x77), tokenContract)    // 32 bytes tokenContract (ABI-encoded)
            mstore(add(ptr, 0x97), tokenId)          // 32 bytes tokenId

            // CREATE2 salt = keccak256(salt ++ chainId ++ tokenContract ++ tokenId)
            let creationSalt := keccak256(add(ptr, 0x37), 0x80)

            // Deploy via CREATE2
            let created := create2(0, ptr, 0xb7, creationSalt)

            // If CREATE2 returns 0, account may already exist at deterministic address
            if iszero(created) {
                let initCodeHash := keccak256(ptr, 0xb7)
                // Compute expected CREATE2 address
                mstore8(0x00, 0xff)
                mstore(0x01, shl(96, address()))
                mstore(0x15, creationSalt)
                mstore(0x35, initCodeHash)
                created := and(keccak256(0x00, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)

                if iszero(extcodesize(created)) {
                    // AccountCreationFailed()
                    mstore(0x00, 0xd786d393)
                    revert(0x1c, 0x04)
                }
            }

            // Emit ERC6551AccountCreated event
            mstore(ptr, created)
            mstore(add(ptr, 0x20), salt)
            mstore(add(ptr, 0x40), chainId)
            log4(
                ptr,
                0x60,
                // keccak256("ERC6551AccountCreated(address,address,bytes32,uint256,address,uint256)")
                0x79f19b3655ee38b1ce526556b7731a20c8f218fbda4a3990b6cc4172fdf88722,
                implementation,
                tokenContract,
                tokenId
            )

            mstore(0x00, created)
            return(0x00, 0x20)
        }
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address) {
        assembly {
            let ptr := mload(0x40)

            // Build the same init code as createAccount
            mstore(ptr, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(96, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            mstore(add(ptr, 0x37), salt)
            mstore(add(ptr, 0x57), chainId)
            mstore(add(ptr, 0x77), tokenContract)
            mstore(add(ptr, 0x97), tokenId)

            let creationSalt := keccak256(add(ptr, 0x37), 0x80)
            let initCodeHash := keccak256(ptr, 0xb7)

            // CREATE2 address: keccak256(0xff ++ deployer ++ salt ++ initCodeHash)[12:]
            mstore8(0x00, 0xff)
            mstore(0x01, shl(96, address()))
            mstore(0x15, creationSalt)
            mstore(0x35, initCodeHash)

            let computed := keccak256(0x00, 0x55)
            computed := and(computed, 0xffffffffffffffffffffffffffffffffffffffff)

            mstore(0x00, computed)
            return(0x00, 0x20)
        }
    }
}
