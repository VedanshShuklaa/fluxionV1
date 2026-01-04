// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FluxionTypes} from "../shared/FluxionTypes.sol";

interface IPoolRegistry {
    /// @notice Returns the PoolConfig for a poolId
    function getPoolConfig(uint256 poolId) external view returns (FluxionTypes.PoolConfig memory);

    /// @notice Returns a list of poolIds registered for a given chainSelector (may be empty)
    function getPoolIdsForChain(uint64 chainSelector) external view returns (uint256[] memory);

    /// @notice Returns all known poolIds
    function getAllPoolIds() external view returns (uint256[] memory);

    /// @notice Checks if an executor is valid for a given chain
    function isValidExecutor(uint64 chainSelector, address executor) external view returns (bool);
    
}