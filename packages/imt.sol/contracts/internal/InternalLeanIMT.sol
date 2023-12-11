// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {SNARK_SCALAR_FIELD} from "../Constants.sol";

struct LeanIMTData {
    // Tracks the current number of leaves in the tree.
    uint256 size;
    // Represents the current depth of the tree, which can increase as new leaves are inserted.
    uint256 depth;
    // A mapping from each level of the tree to the rightmost node at that level.
    // Used for efficient updates and root calculations.
    mapping(uint256 => uint256) rightmostNodes;
    // A mapping from leaf values to their respective indices in the tree.
    // This facilitates checks for leaf existence and retrieval of leaf positions.
    mapping(uint256 => uint256) leaves;
}

error WrongSiblingNodes();
error LeafGreaterThanSnarkScalarField();
error LeafCannotBeZero();
error LeafAlreadyExists();
error LeafDoesNotExist();

/// @title Lean Incremental binary Merkle tree.
/// @dev The LeanIMT is an optimized version of the BinaryIMT.
/// This implementation eliminates the use of zeroes, and make the tree depth dynamic.
/// When a node doesn't have the right child, instead of using a zero hash as in the BinaryIMT,
/// the node's value becomes that of its left child. Furthermore, rather than utilizing a static tree depth,
/// it is updated based on the number of leaves in the tree. This approach
/// results in the calculation of significantly fewer hashes, making the tree more efficient.
library InternalLeanIMT {
    /// @dev Inserts a new leaf into the incremental merkle tree.
    /// The function ensures that the leaf is valid according to the
    /// constraints of the tree and then updates the tree's structure accordingly.
    /// @param self: A storage reference to the 'LeanIMTData' struct.
    /// @param leaf: The value of the new leaf to be inserted into the tree.
    /// @return The new hash of the node after the leaf has been inserted.
    function _insert(LeanIMTData storage self, uint256 leaf) internal returns (uint256) {
        if (leaf >= SNARK_SCALAR_FIELD) {
            revert LeafGreaterThanSnarkScalarField();
        } else if (leaf == 0) {
            revert LeafCannotBeZero();
        } else if (_has(self, leaf)) {
            revert LeafAlreadyExists();
        }

        while (2 ** self.depth < self.size + 1) {
            self.depth += 1;
        }

        uint256 index = self.size;
        uint256 node = leaf;

        for (uint256 level = 0; level < self.depth; ) {
            if ((index >> level) & 1 == 1) {
                node = PoseidonT3.hash([self.rightmostNodes[level], node]);
            } else {
                self.rightmostNodes[level] = node;
            }

            unchecked {
                ++level;
            }
        }

        self.size += 1;

        self.rightmostNodes[self.depth] = node;
        self.leaves[leaf] = self.size;

        return node;
    }

    /// @dev Updates the value of an existing leaf and recalculates hashes
    /// to maintain tree integrity.
    /// @param self: A storage reference to the 'LeanIMTData' struct.
    /// @param oldLeaf: The value of the leaf that is to be updated.
    /// @param newLeaf: The new value that will replace the oldLeaf in the tree.
    /// @param siblingNodes: An array of sibling nodes that are necessary to recalculate the path to the root.
    /// @return The new hash of the updated node after the leaf has been updated.
    function _update(
        LeanIMTData storage self,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256[] calldata siblingNodes
    ) internal returns (uint256) {
        if (newLeaf >= SNARK_SCALAR_FIELD) {
            revert LeafGreaterThanSnarkScalarField();
        } else if (!_has(self, oldLeaf)) {
            revert LeafDoesNotExist();
        } else if (newLeaf != 0 && _has(self, newLeaf)) {
            revert LeafAlreadyExists();
        }

        uint256 index = _indexOf(self, oldLeaf);
        uint256 node = newLeaf;
        uint256 oldRoot = oldLeaf;

        // A counter that adjusts the level at which sibling nodes are
        // accessed and updated during the tree's update process.
        // It ensures that the update function correctly navigates and
        // modifies the tree's nodes at the appropriate levels, accounting
        // for situations where not every level of the tree requires an
        // update or a hash calculation.
        uint256 s = 0;

        // The number of siblings of a proof can be less than
        // the depth of the tree, because in some levels it might not
        // be necessary to hash any value.
        for (uint256 i = 0; i < siblingNodes.length; ) {
            if (siblingNodes[i] >= SNARK_SCALAR_FIELD) {
                revert LeafGreaterThanSnarkScalarField();
            }

            uint256 level = i + s;

            if (oldRoot == self.rightmostNodes[level]) {
                self.rightmostNodes[level] = node;

                if (oldRoot == self.rightmostNodes[level + 1]) {
                    s += 1;
                }

                uint256 j = 0;

                while (oldRoot == self.rightmostNodes[level + j + 1]) {
                    self.rightmostNodes[level + j + 1] = node;

                    unchecked {
                        ++s;
                        ++j;
                    }
                }

                level = i + s;
            }

            if ((index >> level) & 1 != 0) {
                node = PoseidonT3.hash([siblingNodes[i], node]);
                oldRoot = PoseidonT3.hash([siblingNodes[i], oldRoot]);
            } else {
                node = PoseidonT3.hash([node, siblingNodes[i]]);
                oldRoot = PoseidonT3.hash([oldRoot, siblingNodes[i]]);
            }

            unchecked {
                ++i;
            }
        }

        if (oldRoot != _root(self)) {
            revert WrongSiblingNodes();
        }

        self.rightmostNodes[self.depth] = node;
        self.leaves[newLeaf] = self.leaves[oldLeaf];
        self.leaves[oldLeaf] = 0;

        return node;
    }

    /// @dev Removes a leaf from the tree by setting its value to zero.
    /// This function utilizes the update function to set the leaf's value
    /// to zero and update the tree's state accordingly.
    /// @param self: A storage reference to the 'LeanIMTData' struct.
    /// @param oldLeaf: The value of the leaf to be removed.
    /// @param siblingNodes: An array of sibling nodes required for updating the path to the root after removal.
    /// @return The new root hash of the tree after the leaf has been removed.
    function _remove(
        LeanIMTData storage self,
        uint256 oldLeaf,
        uint256[] calldata siblingNodes
    ) internal returns (uint256) {
        return _update(self, oldLeaf, 0, siblingNodes);
    }

    /// @dev Checks if a leaf exists in the tree.
    /// @param self: A storage reference to the 'LeanIMTData' struct.
    /// @param leaf: The value of the leaf to check for existence.
    /// @return A boolean value indicating whether the leaf exists in the tree.
    function _has(LeanIMTData storage self, uint256 leaf) internal view returns (bool) {
        return self.leaves[leaf] != 0;
    }

    /// @dev Retrieves the index of a given leaf in the tree.
    /// @param self: A storage reference to the 'LeanIMTData' struct.
    /// @param leaf: The value of the leaf whose index is to be found.
    /// @return The index of the specified leaf within the tree. If the leaf is not present, the function returns 0.
    function _indexOf(LeanIMTData storage self, uint256 leaf) internal view returns (uint256) {
        return self.leaves[leaf] - 1;
    }

    /// @dev Retrieves the root of the tree from the 'rightmostNodes' mapping using the
    /// current tree depth.
    /// @param self: A storage reference to the 'LeanIMTData' struct.
    /// @return The root hash of the tree.
    function _root(LeanIMTData storage self) internal view returns (uint256) {
        return self.rightmostNodes[self.depth];
    }
}