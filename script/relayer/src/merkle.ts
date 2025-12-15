import { keccak256, concat, toBeHex } from 'ethers';

export interface MerkleTree {
  root: string;
  leaves: string[];
  layers: string[][];
}

export interface MerkleProof {
  leaf: string;
  proof: string[];
  index: number;
}

/**
 * Builds a Merkle tree from an array of leaves
 * @param leaves Array of leaf hashes
 * @returns Merkle tree with root and all layers
 */
export function buildMerkleTree(leaves: string[]): MerkleTree {
  if (leaves.length === 0) {
    throw new Error('Cannot build tree from empty leaves');
  }
  
  // Sort leaves for deterministic tree construction
  const sortedLeaves = [...leaves].sort();
  
  const layers: string[][] = [sortedLeaves];
  
  // Build tree bottom-up
  while (layers[layers.length - 1].length > 1) {
    const currentLayer = layers[layers.length - 1];
    const nextLayer: string[] = [];
    
    for (let i = 0; i < currentLayer.length; i += 2) {
      if (i + 1 < currentLayer.length) {
        // Hash pair
        const left = currentLayer[i];
        const right = currentLayer[i + 1];
        const hash = hashPair(left, right);
        nextLayer.push(hash);
      } else {
        // Odd number of nodes, promote the last one
        nextLayer.push(currentLayer[i]);
      }
    }
    
    layers.push(nextLayer);
  }
  
  return {
    root: layers[layers.length - 1][0],
    leaves: sortedLeaves,
    layers,
  };
}

/**
 * Generates a Merkle proof for a specific leaf
 * @param tree Merkle tree
 * @param leaf Leaf hash to generate proof for
 * @returns Merkle proof
 */
export function generateProof(tree: MerkleTree, leaf: string): MerkleProof {
  const index = tree.leaves.indexOf(leaf);
  
  if (index === -1) {
    throw new Error('Leaf not found in tree');
  }
  
  const proof: string[] = [];
  let currentIndex = index;
  
  // Traverse from leaf to root
  for (let i = 0; i < tree.layers.length - 1; i++) {
    const layer = tree.layers[i];
    const isRightNode = currentIndex % 2 === 1;
    const siblingIndex = isRightNode ? currentIndex - 1 : currentIndex + 1;
    
    if (siblingIndex < layer.length) {
      proof.push(layer[siblingIndex]);
    }
    
    currentIndex = Math.floor(currentIndex / 2);
  }
  
  return {
    leaf,
    proof,
    index,
  };
}

/**
 * Verifies a Merkle proof
 * @param proof Merkle proof
 * @param root Expected root hash
 * @returns True if proof is valid
 */
export function verifyProof(proof: MerkleProof, root: string): boolean {
  let computedHash = proof.leaf;
  let index = proof.index;
  
  for (const sibling of proof.proof) {
    if (index % 2 === 0) {
      // Current node is left
      computedHash = hashPair(computedHash, sibling);
    } else {
      // Current node is right
      computedHash = hashPair(sibling, computedHash);
    }
    
    index = Math.floor(index / 2);
  }
  
  return computedHash === root;
}

/**
 * Hashes a pair of nodes
 * @param left Left node hash
 * @param right Right node hash
 * @returns Combined hash
 */
function hashPair(left: string, right: string): string {
  // Sort to ensure deterministic hashing
  const [first, second] = left < right ? [left, right] : [right, left];
  
  // Concatenate and hash
  const combined = concat([first, second]);
  return keccak256(combined);
}

/**
 * Generates proofs for all leaves in a tree
 * @param tree Merkle tree
 * @returns Array of proofs for each leaf
 */
export function generateAllProofs(tree: MerkleTree): MerkleProof[] {
  return tree.leaves.map(leaf => generateProof(tree, leaf));
}

/**
 * Computes root from leaves (utility function)
 * @param leaves Array of leaf hashes
 * @returns Root hash
 */
export function computeRoot(leaves: string[]): string {
  const tree = buildMerkleTree(leaves);
  return tree.root;
}
