// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Path
/// @notice Functions for handling path data for multihop swaps
library Path {
    /// @dev The length of the bytes encoded address
    uint256 private constant ADDR_SIZE = 20;
    /// @dev The length of the bytes encoded fee
    uint256 private constant FEE_SIZE = 3;

    /// @dev The offset of a single token address and pool fee
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + FEE_SIZE;
    /// @dev The offset of an encoded pool key
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    /// @dev The minimum length of an encoding that contains 2 or more pools
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET;

    /// @notice Returns true iff the path contains two or more pools
    /// @param path The encoded swap path
    /// @return True if path contains two or more pools, otherwise false

    function hasMultiplePools(bytes calldata path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    function hasMultiplePoolsMemory(bytes memory path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    /// @notice Decodes the first pool in path
    /// @param path The bytes encoded swap path
    /// @return tokenA The first token of the given pool
    /// @return tokenB The second token of the given pool
    /// @return fee The fee level of the pool
    function decodeFirstPool(bytes calldata path)
        internal
        pure
        returns (
            address tokenA,
            address tokenB,
            uint24 fee
        )
    {
        tokenA = address(bytes20(path[0:ADDR_SIZE]));
        fee = uint24(bytes3(path[ADDR_SIZE:NEXT_OFFSET]));
        tokenB = address(bytes20(path[NEXT_OFFSET:POP_OFFSET]));
    }

    function decodeFirstPoolMemory(bytes memory path)
        internal
        pure
        returns (
            address tokenA,
            address tokenB,
            uint24 fee
        )
    {
        tokenA = toAddress(path, 0);
        fee = toUint24(path, ADDR_SIZE);
        tokenB = toAddress(path, NEXT_OFFSET);
    }

    /// @notice Skips a token + fee from the buffer and returns the remainder
    /// @param path The swap path
    /// @return The remaining token + fee
    function skipToken(bytes calldata path) internal pure returns (bytes calldata) {
        return path[NEXT_OFFSET:];
    }

    function skipTokenMemory(bytes memory path) internal pure returns (bytes memory) {
        bytes memory res = new bytes(path.length - NEXT_OFFSET);
        for (uint i = 0; i < res.length; i++) {
            res[i] = path[i + NEXT_OFFSET];
        }
        return res;
    }

    function toAddress(bytes memory _bytes, uint256 _start) private pure returns (address) {
        require(_bytes.length >= _start + 20, "OOB");
        address tempAddress;
        assembly {
            tempAddress := shr(96, mload(add(add(_bytes, 32), _start)))
        }
        return tempAddress;
    }

    function toUint24(bytes memory _bytes, uint256 _start) private pure returns (uint24) {
        require(_bytes.length >= _start + 3, "OOB");
        uint24 tempUint;
        assembly {
            tempUint := shr(232, mload(add(add(_bytes, 32), _start)))
        }
        return uint24(tempUint); // Cast to uint24
    }
}
