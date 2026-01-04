// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FluxionTypes} from "../shared/FluxionTypes.sol";

contract PoolRegistry is AccessControl {
    bytes32 public constant REGISTRY_MANAGER = keccak256("REGISTRY_MANAGER");

    mapping(uint256 => FluxionTypes.PoolConfig) private _poolConfigs;
    uint256[] private _allPoolIds;

    event PoolAdded(uint256 indexed poolId, uint64 indexed chainSelector, address executor, address adapter);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_MANAGER, admin);
    }

    /* ============ VIEW FUNCTIONS (Vault/Brain Essentials) ============ */

    function getPoolConfig(uint256 poolId) external view returns (FluxionTypes.PoolConfig memory) {
        return _poolConfigs[poolId];
    }

    function getAllPoolIds() external view returns (uint256[] memory) {
        return _allPoolIds;
    }

    function isValidExecutor(uint64 chainSelector, address executor) external view returns (bool) {
        for (uint256 i = 0; i < _allPoolIds.length; i++) {
            FluxionTypes.PoolConfig memory cfg = _poolConfigs[_allPoolIds[i]];
            if (cfg.chainSelector == chainSelector && cfg.executor == executor) {
                return true;
            }
        }
        return false;
    }

    /* ============ MANAGER ACTIONS ============ */

    function addPool(
        uint64 chainSelector,
        address executor,
        address adapter,
        bool isActive
    ) external onlyRole(REGISTRY_MANAGER) returns (uint256) {
        // Use the simple hash as the ID
        uint256 poolId = uint256(keccak256(abi.encodePacked(chainSelector, executor, adapter)));
        
        require(_poolConfigs[poolId].executor == address(0), "exists");

        _poolConfigs[poolId] = FluxionTypes.PoolConfig({
            chainSelector: chainSelector,
            executor: executor,
            adapter: adapter,
            isActive: isActive
        });

        _allPoolIds.push(poolId);

        emit PoolAdded(poolId, chainSelector, executor, adapter);
        return poolId;
    }

    // Simple toggle for the demo
    function setPoolActive(uint256 poolId, bool active) external onlyRole(REGISTRY_MANAGER) {
        _poolConfigs[poolId].isActive = active;
    }
}