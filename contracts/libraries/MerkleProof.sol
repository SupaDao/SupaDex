// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title MerkleProof
/// @notice Gas-optimized merkle proof verification library
/// @dev Provides efficient merkle tree verification for batch auction settlement
library MerkleProof {
    
    /// @notice Verifies a merkle proof
    /// @param proof Array of sibling hashes
    /// @param root The merkle root to verify against
    /// @param leaf The leaf node to verify
    /// @return valid Whether the proof is valid
    /// @dev Uses assembly for gas optimization
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool valid) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }
        
        return computedHash == root;
    }
    
    /// @notice Verifies multiple proofs efficiently
    /// @param proofs Array of proof arrays
    /// @param root The merkle root
    /// @param leaves The leaf nodes
    /// @return valid Whether all proofs are valid
    /// @dev Batch verification for gas efficiency
    function verifyMultiProof(
        bytes32[][] memory proofs,
        bytes32 root,
        bytes32[] memory leaves
    ) internal pure returns (bool valid) {
        require(proofs.length == leaves.length, "Length mismatch");
        
        for (uint256 i = 0; i < leaves.length; i++) {
            if (!verify(proofs[i], root, leaves[i])) {
                return false;
            }
        }
        
        return true;
    }
    
    /// @notice Hashes a pair of nodes
    /// @param a First node
    /// @param b Second node
    /// @return hash The combined hash
    /// @dev Orders hashes to ensure deterministic tree structure
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 hash) {
        assembly {
            // Sort the hashes
            switch lt(a, b)
            case 0 {
                mstore(0x00, b)
                mstore(0x20, a)
            }
            default {
                mstore(0x00, a)
                mstore(0x20, b)
            }
            hash := keccak256(0x00, 0x40)
        }
    }
    
    /// @notice Computes the merkle root from leaves
    /// @param leaves Array of leaf hashes
    /// @return root The computed merkle root
    /// @dev Used for testing and verification
    function computeRoot(bytes32[] memory leaves) internal pure returns (bytes32 root) {
        require(leaves.length > 0, "Empty leaves");
        
        uint256 n = leaves.length;
        uint256 offset = 0;
        
        // Build tree bottom-up
        while (n > 1) {
            for (uint256 i = 0; i < n / 2; i++) {
                leaves[offset + i] = _hashPair(
                    leaves[offset + i * 2],
                    leaves[offset + i * 2 + 1]
                );
            }
            
            // Handle odd number of nodes
            if (n % 2 == 1) {
                leaves[offset + n / 2] = leaves[offset + n - 1];
                n = n / 2 + 1;
            } else {
                n = n / 2;
            }
        }
        
        return leaves[0];
    }
}
